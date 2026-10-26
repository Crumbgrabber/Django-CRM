import { fail } from '@sveltejs/kit';
import { listRecurringInvoices, toggleRecurring, FILTER_FIELDS } from '#lib/server/v2/recurring.js';
import { readFilters, buildFilterQuery } from '#lib/server/v2/filter-params.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * The schedules worklist. `load` returns `{ schedules, totals }`. The names the
 * page reads; the data layer's own field is `schedules`, so no rename here.
 *
 * `is_active` is forwarded to the API rather than derived from the rows after
 * the fact, so the four header figures (all computed from what comes back)
 * agree with the table underneath them.
 */
export const load: PageServerLoad = async ({ cookies, url }) => {
  const params = buildFilterQuery(FILTER_FIELDS, readFilters(url, 'recurring'));
  return await listRecurringInvoices({ cookies }, params);
};

export const actions: Actions = {
  /**
   * Pause a live schedule or resume a paused one. The id comes from the row, and
   * the API decides whether this caller may toggle it. A member who is neither
   * creator nor assignee gets the same 404 as a missing schedule.
   */
  toggle: async ({ cookies, request }) => {
    const form = await request.formData();
    const id = form.get('id')?.toString();
    if (!id) return fail(400, { error: 'Which schedule? None was given.' });

    try {
      await toggleRecurring({ cookies }, id);
    } catch (err) {
      return fail(apiStatus(err) === 404 ? 404 : 400, {
        error: readableError(err, 'Could not change this schedule.')
      });
    }
    return { toggled: true };
  }
};
