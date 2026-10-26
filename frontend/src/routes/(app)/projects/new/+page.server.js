import { fail, redirect } from '@sveltejs/kit';
import { createProject, getProjectDraft, getProjectFormOptions } from '#lib/server/v2/projects.js';
import { getModules } from '#lib/server/v2/modules.js';
import {
  fieldsForNew,
  readCustomFields,
  saveRefusal
} from '#lib/server/v2/record-custom-fields.js';
import { isOn } from '#lib/v2/modules.js';
import { draftValues, isUuid, projectBody, projectValues } from '#lib/v2/projects.js';

/**
 * The new-project form. `?deal=<id>` fills it from that deal's draft
 * (`from-deal/`), which saves nothing; a deal the caller cannot see gives no
 * draft and the form opens empty with a line saying so.
 *
 * @type {import('./$types').PageServerLoad}
 */
export async function load(event) {
  const { url, locals } = event;
  const dealId = url.searchParams.get('deal') ?? '';
  const modules = (await getModules(event))?.modules ?? null;
  const dealsOn = isOn(modules, 'deals');

  const [options, draft, customFields] = await Promise.all([
    getProjectFormOptions(event, { dealsOn }),
    dealsOn && isUuid(dealId) ? getProjectDraft(event, dealId) : null,
    fieldsForNew(event.cookies, 'Project')
  ]);

  const fromDraft = draftValues(draft);
  const values = {
    status: 'active',
    billing_type: 'time_and_materials',
    currency: locals.org_settings?.default_currency || 'USD',
    assigned_to: [],
    rates: [],
    ...Object.fromEntries(Object.entries(fromDraft).filter(([, v]) => v !== '' && v !== null))
  };

  // The deal's account and the deal itself may be outside what the pickers
  // list; kept as options of their own so the draft's choice survives.
  const accountName = typeof draft?.account === 'object' ? draft.account?.name : '';
  return {
    ...options,
    values,
    customFields,
    draftMissed: Boolean(dealId) && !draft,
    fromDeal: draft ? { id: fromDraft.deal, name: fromDraft.name } : null,
    stored: draft
      ? {
          account: fromDraft.account
            ? { id: fromDraft.account, name: accountName || 'The deal’s account' }
            : null,
          deal: fromDraft.deal ? { id: fromDraft.deal, name: fromDraft.name || 'The deal' } : null
        }
      : {}
  };
}

/** @type {import('./$types').Actions} */
export const actions = {
  async create(event) {
    const form = await event.request.formData();
    const values = projectValues(form);

    const custom = await readCustomFields(event.cookies, 'Project', form);
    if (custom.refusal) return fail(503, { values, ...custom.refusal });
    if (custom.values) values.custom_fields = custom.values;

    const { body, errors } = projectBody(values);
    if (errors.length) return fail(400, { values, error: errors.join(' ') });

    /** @type {{ id: string | null }} */
    let created;
    try {
      created = await createProject(event, body);
    } catch (err) {
      return fail(400, {
        values,
        ...saveRefusal(err, custom.definitions, 'Could not create the project.')
      });
    }
    redirect(303, created.id ? `/projects/${created.id}` : '/projects');
  }
};
