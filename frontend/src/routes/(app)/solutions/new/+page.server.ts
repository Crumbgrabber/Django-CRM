import { fail, redirect } from '@sveltejs/kit';
import { createArticle } from '#lib/server/v2/solutions.js';
import { getTags } from '#lib/server/v2/tags.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { isOrgAdmin } from '#lib/admin.js';
import type { components } from '#lib/api-schema.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ cookies, locals }) => {
  return {
    // `getTags` asks for archived ones too, for the settings page. Filtered
    // here because `_apply_tags` refuses an archived tag, so offering one
    // would be a checkbox that silently does nothing on save.
    tags: ((await getTags({ cookies })).tags ?? []).filter((t) => t.is_active),
    // Decides whether the form offers "Approved" and the publish switch at
    // all. The API refuses both for anyone else, so offering them would be a
    // form that fails on submit for reasons the writer cannot see.
    canRelease: isOrgAdmin(locals.profile)
  };
};

export const actions: Actions = {
  create: async ({ cookies, request }) => {
    const form = await request.formData();

    const values = {
      title: form.get('title')?.toString().trim() ?? '',
      description: form.get('description')?.toString().trim() ?? '',
      status: form.get('status')?.toString() || 'draft',
      // A checkbox that is off submits nothing at all, which on a *create* is
      // unambiguous. There is no stored value for "unchanged" to mean.
      is_published: form.get('is_published') === 'on',
      tags: form.getAll('tags').map(String)
    };

    let created: components['schemas']['Solution'];
    try {
      created = await createArticle({ cookies }, values);
    } catch (err) {
      return fail(400, { values, error: readableError(err, 'Could not save this article.') });
    }

    redirect(303, `/solutions/${created.id}`);
  }
};
