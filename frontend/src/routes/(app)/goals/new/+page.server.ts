import { fail, redirect } from '@sveltejs/kit';
import {
  getGoalFormOptions,
  createGoal,
  weightsFromForm,
  EDITABLE_FIELDS,
  type GoalFormField,
  type GoalValues
} from '#lib/server/v2/goals.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * Creating a goal.
 *
 * Admin-only. The load returns `can_edit: false` for a non-admin so the page can
 * render an "admins only" state instead of a form, and the create action is
 * gated again by the backend, `POST /api/opportunities/goals/` 403s a non-admin
 * regardless of what reaches it.
 */
export const load: PageServerLoad = async (event) => {
  return await getGoalFormOptions(event);
};

export const actions: Actions = {
  create: async (event) => {
    const form = await event.request.formData();

    const values: GoalValues = {};
    // Text and select fields, plus the single `target` picker that stands in
    // for assigned_to/team. is_active is omitted on create. A new goal is
    // active (the model default), so there is nothing to choose yet.
    const fields: GoalFormField[] = [...EDITABLE_FIELDS, 'target'];
    for (const field of fields) {
      if (form.has(field)) values[field] = form.get(field)?.toString().trim() ?? '';
    }
    // The weight inputs are absent from the DOM on an ACTIVITIES goal, so this
    // sends `{}` for one, which is what the backend accepts there.
    values.type_weights = weightsFromForm(form);

    try {
      await createGoal(event, values);
    } catch (err) {
      if (apiStatus(err) === 403) {
        return fail(403, { values, error: 'Only an admin can create goals.' });
      }
      return fail(400, {
        values,
        error: readableError(err, 'Could not create this goal.')
      });
    }

    redirect(303, '/goals');
  }
};
