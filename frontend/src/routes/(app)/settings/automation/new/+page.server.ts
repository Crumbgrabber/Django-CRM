import { redirect } from '@sveltejs/kit';
import { getCatalogue, createRule, ruleFromForm, refusedSave } from '#lib/server/v2/automation.js';
import { apiStatus } from '#lib/api-errors.js';
import type { components } from '#lib/api-schema.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ cookies }) => {
  try {
    return { catalogue: await getCatalogue({ cookies }) };
  } catch (err) {
    if (apiStatus(err) === 403) return { forbidden: true as const };
    throw err;
  }
};

export const actions: Actions = {
  async save(event) {
    const form = await event.request.formData();
    let created: components['schemas']['Rule'];
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
