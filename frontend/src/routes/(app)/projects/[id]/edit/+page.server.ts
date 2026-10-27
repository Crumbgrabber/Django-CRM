import { error, fail, redirect } from '@sveltejs/kit';
import { getProject, getProjectFormOptions, updateProject } from '#lib/server/v2/projects.js';
import { getModules } from '#lib/server/v2/modules.js';
import {
  fieldDefinitions,
  fieldsForEdit,
  readCustomFields,
  saveRefusal
} from '#lib/server/v2/record-custom-fields.js';
import { isOn } from '#lib/v2/modules.js';
import { projectBody, projectValues } from '#lib/v2/projects.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

/** A stored figure as the form's text, blank when unset. */
const text = (n: number | null) => (n === null ? '' : String(n));

/**
 * The edit form, filled from the record. A PATCH: what the form did not
 * render is not sent, and `rates`, when sent, replaces the whole list.
 */
export const load: PageServerLoad = async (event) => {
  const modules = (await getModules(event))?.modules ?? null;
  const [detail, options, definitions] = await Promise.all([
    getProject(event, event.params.id),
    getProjectFormOptions(event, { dealsOn: isOn(modules, 'deals') }),
    fieldDefinitions(event.cookies, 'Project')
  ]);
  // Display only; the PATCH asks the API's edit rule again.
  if (!detail.canEdit) error(403);

  const p = detail.project;
  return {
    ...options,
    project: { id: p.id, name: p.name },
    values: {
      name: p.name,
      account: p.account.id ?? '',
      deal: p.deal?.id ?? '',
      status: p.status,
      billing_type: p.billing_type,
      currency: p.currency,
      budget_hours: text(p.budget_hours),
      budget_amount: text(p.budget_amount),
      hourly_rate: text(p.hourly_rate),
      retainer_fee: text(p.retainer_fee),
      retainer_hours: text(p.retainer_hours),
      retainer_rollover: p.retainer_rollover,
      retainer_overage_rate: text(p.retainer_overage_rate),
      retainer_carried_hours: text(p.retainer_carried_hours),
      start_date: p.start_date ?? '',
      due_date: p.due_date ?? '',
      description: p.description,
      assigned_to: p.assigned_to.map((x) => x.id),
      rates: p.rates.map((r) => ({
        profile: r.profile.id,
        hourly_rate: text(r.hourly_rate)
      }))
    },
    stored: {
      account: p.account.id ? p.account : null,
      deal: p.deal,
      people: [
        ...new Map(
          [...p.assigned_to, ...p.rates.map((r) => r.profile)].map((x) => [x.id, x])
        ).values()
      ]
    },
    customFields: fieldsForEdit({ custom_field_definitions: definitions }, p.custom_fields)
  };
};

export const actions: Actions = {
  async save(event) {
    const form = await event.request.formData();
    const values = projectValues(form);

    const custom = await readCustomFields(event.cookies, 'Project', form);
    if (custom.refusal) return fail(503, { values, ...custom.refusal });
    if (custom.values) values.custom_fields = custom.values;

    const { body, errors } = projectBody(values);
    if (errors.length) return fail(400, { values, error: errors.join(' ') });

    try {
      await updateProject(event, event.params.id, body);
    } catch (err) {
      return fail(apiStatus(err) === 404 ? 404 : 400, {
        values,
        ...saveRefusal(err, custom.definitions, 'Could not save the project.')
      });
    }
    redirect(303, `/projects/${event.params.id}`);
  }
};
