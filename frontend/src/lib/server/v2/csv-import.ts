/**
 * Form-action half of the spreadsheet importers (contacts, tickets and leads).
 *
 * `ImportFlow` (contacts and leads) and `TicketImportDrawer` post the chosen
 * file to `?/importPreview` and `?/importCommit` on the list page and read the
 * result under those same keys, `importError`, `importErrors` and
 * `importSkipped` on failure. This forwards the file, and the `mapping` field
 * when the form has one, to Django as multipart and maps the reply onto that
 * shape. It never gates: the import views decide who may import (admin or
 * sales access), check the mapping, cap the size and rows, throttle, and scope
 * every write to the caller's org.
 */
import { fail, type Cookies } from '@sveltejs/kit';
import { apiRequest } from '#lib/api-helpers.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';

/**
 * @param path Django endpoint, e.g. `/contacts/import/preview/`
 * @param key where the client reads the success body
 */
export async function forwardCsvImport(
  { request, cookies }: { request: Request; cookies: Cookies },
  path: string,
  key: 'importPreview' | 'importCommit'
) {
  const form = await request.formData();
  const file = form.get('file');
  if (!(file instanceof File) || file.size === 0) {
    return fail(400, { importError: 'Choose a file.' });
  }
  const body = new FormData();
  body.set('file', file, file.name || 'upload.csv');
  const mapping = form.get('mapping');
  if (typeof mapping === 'string') body.set('mapping', mapping);
  try {
    // Quiet: an import's error reply carries the skipped rows' cells, which
    // must not reach the server log.
    return {
      [key]: await apiRequest(path, { method: 'POST', body, quietErrors: true }, { cookies })
    };
  } catch (err) {
    const status = apiStatus(err);
    if (!status) throw err;
    const data = apiErrorBody(err) ?? {};
    return fail(status, {
      importError:
        status === 403
          ? 'Importing needs an admin, or a member with sales access.'
          : status === 429
            ? 'Too many tries in a minute. Wait a moment, then try again.'
            : String(data.message || data.header_error || 'Import failed'),
      importErrors: Array.isArray(data.errors) ? data.errors : [],
      // A mapped commit with nothing importable answers 400 with the rows it
      // skipped, so the client can still say why.
      importSkipped: Array.isArray(data.skipped) ? data.skipped : []
    });
  }
}
