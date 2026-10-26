/**
 * The `comment` form action of a record that takes a comment and a file in
 * one POST to its detail route, as deals and projects do. Either may come
 * alone; a submit with neither is refused here so the API is not asked to
 * store nothing. Who wrote it and which org it is in are the API's to set.
 */
import { fail, type Action, type Cookies } from '@sveltejs/kit';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';

/** The comment text and the picked file, if any, off a submitted form. */
export function readNote(form: FormData): { comment: string; file: File | null } {
  const comment = form.get('comment')?.toString().trim() ?? '';
  const picked = form.get('attachment');
  const file =
    picked && typeof picked === 'object' && 'size' in picked && picked.size > 0
      ? (picked as File)
      : null;
  return { comment, file };
}

export function commentAction(
  post: (
    event: { cookies: Cookies },
    id: string,
    comment: string,
    file: File | null
  ) => Promise<unknown>
): Action<{ id: string }> {
  return async ({ cookies, params, request }) => {
    const { comment, file } = readNote(await request.formData());
    if (!comment && !file) {
      return fail(400, { noteError: 'Write a comment or attach a file first.' });
    }
    try {
      await post({ cookies }, params.id, comment, file);
    } catch (err) {
      const status = apiStatus(err);
      const code = status !== undefined && status >= 400 && status < 500 ? status : 400;
      return fail(code, { noteError: readableError(err, 'Could not save that.') });
    }
    return { commented: true };
  };
}
