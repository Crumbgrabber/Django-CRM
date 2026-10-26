import { fail } from '@sveltejs/kit';
import { getSupportTicket, replyToSupportTicket } from '#lib/server/v2/support.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ cookies, params }) => {
  return { ticket: await getSupportTicket({ cookies }, params.id) };
};

export const actions: Actions = {
  reply: async ({ cookies, params, request }) => {
    const form = await request.formData();
    const body = form.get('body')?.toString().trim() ?? '';
    const picked = form.get('attachment');
    const attachment =
      picked && typeof picked === 'object' && 'size' in picked && picked.size > 0 ? picked : null;
    if (!body && !attachment) {
      return fail(400, { body, error: 'Write a reply or attach a file before sending.' });
    }
    try {
      await replyToSupportTicket({ cookies }, params.id, { body, attachment });
      return { sent: true };
    } catch (error) {
      return fail(400, {
        body,
        error: readableError(error, 'Could not send this reply.')
      });
    }
  }
};
