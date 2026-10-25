/**
 * The `comment` form action of a record that takes a comment and a file in
 * one POST to its detail route, as deals and projects do. Either may come
 * alone; a submit with neither is refused here so the API is not asked to
 * store nothing. Who wrote it and which org it is in are the API's to set.
 */
import { fail } from '@sveltejs/kit';
import { readableError } from '#lib/server/v2/form-errors.js';

/**
 * The comment text and the picked file, if any, off a submitted form.
 *
 * @param {FormData} form
 * @returns {{ comment: string, file: File | null }}
 */
export function readNote(form) {
  const comment = form.get('comment')?.toString().trim() ?? '';
  const picked = form.get('attachment');
  const file =
    picked && typeof picked === 'object' && 'size' in picked && picked.size > 0
      ? /** @type {File} */ (picked)
      : null;
  return { comment, file };
}

/**
 * @param {(event: { cookies: import('@sveltejs/kit').Cookies }, id: string, comment: string, file: File | null) => Promise<unknown>} post
 * @returns {import('@sveltejs/kit').Action<{ id: string }>}
 */
export function commentAction(post) {
  return async ({ cookies, params, request }) => {
    const { comment, file } = readNote(await request.formData());
    if (!comment && !file) {
      return fail(400, { noteError: 'Write a comment or attach a file first.' });
    }
    try {
      await post({ cookies }, params.id, comment, file);
    } catch (/** @type {any} */ err) {
      const code = err?.status >= 400 && err?.status < 500 ? err.status : 400;
      return fail(code, { noteError: readableError(err, 'Could not save that.') });
    }
    return { commented: true };
  };
}
