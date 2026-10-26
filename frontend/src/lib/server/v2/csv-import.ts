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
import type { components } from '#lib/api-schema.js';
import type { Skipped } from '#lib/import/mapping.js';
import type { RowError } from '#lib/utils/csv.js';

type Schemas = components['schemas'];
type ImportReply = {
  '/cases/import/preview/': Schemas['CaseImportPreviewResponse'];
  '/cases/import/commit/': Schemas['CaseImportCommitResponse'];
  '/contacts/import/preview/': Schemas['ContactImportPreviewResponse'];
  '/contacts/import/commit/': Schemas['ContactImportCommitResponse'];
  '/leads/import/preview/': Schemas['LeadImportPreviewResponse'];
  '/leads/import/commit/': Schemas['LeadImportCommitResponse'];
};

/**
 * @param path Django endpoint, e.g. `/contacts/import/preview/`
 * @param key where the client reads the success body
 */
export async function forwardCsvImport<
  P extends keyof ImportReply,
  K extends 'importPreview' | 'importCommit'
>({ request, cookies }: { request: Request; cookies: Cookies }, path: P, key: K) {
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
    const reply: ImportReply[P] = await apiRequest(
      path,
      { method: 'POST', body, quietErrors: true },
      { cookies }
    );
    return { [key]: reply } as Record<K, ImportReply[P]>;
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
      importErrors: (Array.isArray(data.errors) ? data.errors : []) as RowError[],
      // A mapped commit with nothing importable answers 400 with the rows it
      // skipped, so the client can still say why.
      importSkipped: (Array.isArray(data.skipped) ? data.skipped : []) as Skipped[]
    });
  }
}
