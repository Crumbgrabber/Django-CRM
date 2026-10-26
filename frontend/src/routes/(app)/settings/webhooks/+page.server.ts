import { fail } from '@sveltejs/kit';
import { listWebhooks, createWebhook, eventsFromForm } from '#lib/server/v2/webhooks.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';
import type { Actions, PageServerLoad } from './$types';

/**
 * Outbound webhooks: the list and the create panel.
 *
 * Every route underneath is admin-only server-side (`webhooks/views.py`), the
 * list included, so a member gets `forbidden` and an explanation rather than
 * a broken page.
 */
export const load: PageServerLoad = async ({ cookies }) => {
  return await listWebhooks({ cookies });
};

export const actions: Actions = {
  /**
   * The response is the one place the full signing secret appears, besides a
   * rotate. It is handed to the page for this render only.
   */
  async create(event) {
    const form = await event.request.formData();
    const values = {
      url: form.get('url')?.toString().trim() ?? '',
      description: form.get('description')?.toString().trim() ?? '',
      format: form.get('format')?.toString() ?? 'json',
      events: eventsFromForm(form)
    };
    if (!values.events.length) {
      return fail(400, { create: { error: 'Choose at least one event.', values } });
    }
    try {
      const created = await createWebhook(event, values);
      return { created: { id: created.id, url: created.url, secret: created.secret } };
    } catch (err) {
      if (apiStatus(err) === 403) {
        return fail(403, { create: { error: 'Only an admin can add webhooks.', values } });
      }
      return fail(400, {
        create: { error: readableError(err, 'Could not add the webhook.'), values }
      });
    }
  }
};
