import { fail, redirect } from '@sveltejs/kit';
import {
  createTicket,
  getTicketFormOptions,
  type TicketField,
  type TicketValues
} from '#lib/server/v2/tickets.js';
import {
  fieldsForNew,
  readCustomFields,
  saveRefusal
} from '#lib/server/v2/record-custom-fields.js';
import type { components } from '#lib/api-schema.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ cookies, url }) => {
  const [options, customFields] = await Promise.all([
    getTicketFormOptions({ cookies }, url.searchParams.get('account')),
    fieldsForNew(cookies, 'Case')
  ]);
  return { ...options, customFields };
};

export const actions: Actions = {
  create: async ({ cookies, request }) => {
    const form = await request.formData();

    const values: TicketValues = {};
    const fields: TicketField[] = [
      'name',
      'status',
      'priority',
      'case_type',
      'description',
      'account'
    ];
    for (const field of fields) {
      values[field] = form.get(field)?.toString().trim() ?? '';
    }

    const owner = form.get('assigned_to')?.toString().trim() ?? '';
    if (owner) values.assigned_to = owner;
    const contacts = form.getAll('contacts').map((id) => id.toString());
    if (contacts.length) values.contacts = contacts;

    const custom = await readCustomFields(cookies, 'Case', form);
    if (custom.refusal) return fail(503, { values, ...custom.refusal });
    if (custom.values) values.custom_fields = custom.values;

    if (!values.name) {
      const missing: {
        values: typeof values;
        error: string;
        fieldErrors?: Record<string, string>;
      } = { values, error: 'A ticket needs a subject.' };
      return fail(400, missing);
    }

    let created: components['schemas']['CaseCreateResponse'];
    try {
      created = await createTicket({ cookies }, values);
    } catch (err) {
      return fail(400, {
        values,
        ...saveRefusal(err, custom.definitions, 'Could not raise this ticket.')
      });
    }

    // `CaseListView.post` returns the new id, so this lands on the ticket
    // rather than back at a queue where the user has to go and find it.
    redirect(303, created?.id ? `/tickets/${created.id}` : '/tickets');
  }
};
