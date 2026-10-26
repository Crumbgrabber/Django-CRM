import { fail } from '@sveltejs/kit';
import { getTimesheet, stopTimer } from '#lib/server/v2/timesheet.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * `?start=&end=` (YYYY-MM-DD) pick the week; absent, the API picks this week
 * in the org's timezone. The week-nav buttons drive those params.
 */
export const load: PageServerLoad = async ({ cookies, url }) => {
  const start = url.searchParams.get('start') || undefined;
  const end = url.searchParams.get('end') || undefined;
  return await getTimesheet({ cookies }, { start, end });
};

export const actions: Actions = {
  async stop(event) {
    const form = await event.request.formData();
    const entryId = form.get('entry_id')?.toString() ?? '';

    try {
      await stopTimer(event, entryId);
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not stop the timer.') });
    }

    return { stopped: true };
  }
};
