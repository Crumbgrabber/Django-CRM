import { fail } from '@sveltejs/kit';
import {
  getCalendarFeed,
  issueCalendarFeed,
  disableCalendarFeed
} from '#lib/server/v2/calendar-feed.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * Your own task calendar feed. No role check: every member may subscribe to
 * their own tasks, and the API answers only for the caller.
 */
export const load: PageServerLoad = async ({ cookies }) => {
  return { feed: await getCalendarFeed({ cookies }) };
};

export const actions: Actions = {
  /** Turn the feed on, or replace its URL. The new URL is returned once. */
  issue: async ({ cookies }) => {
    try {
      return { url: await issueCalendarFeed({ cookies }) };
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not create the calendar feed.') });
    }
  },

  /** Turn the feed off. The URL stops working at once. */
  disable: async ({ cookies }) => {
    try {
      await disableCalendarFeed({ cookies });
    } catch (err) {
      return fail(400, { error: readableError(err, 'Could not turn the calendar feed off.') });
    }
    return { disabled: true };
  }
};
