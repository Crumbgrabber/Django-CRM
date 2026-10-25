import { redirect } from '@sveltejs/kit';
import { getCatalogue, createRule, ruleFromForm, refusedSave } from '#lib/server/v2/automation.js';
import { apiStatus } from '#lib/api-errors.js';

/** @type {import('./$types').PageServerLoad} */
export async function load({ cookies }) {
  try {
    return { catalogue: await getCatalogue({ cookies }) };
  } catch (err) {
    if (apiStatus(err) === 403) return { forbidden: /** @type {const} */ (true) };
    throw err;
  }
}

/** @type {import('./$types').Actions} */
export const actions = {
  async save(event) {
    const form = await event.request.formData();
    /** @type {import('#lib/api-schema.js').components['schemas']['Rule']} */
    let created;
    try {
      const body = ruleFromForm(form, { create: true });
      body.is_active = form.get('switch_on') === 'true';
      created = await createRule(event, body);
    } catch (err) {
      return refusedSave(err);
    }
    redirect(303, `/settings/automation/${created.id}`);
  }
};
