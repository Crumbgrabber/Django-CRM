/**
 * CSV export of a custom object's list page: `forwardCsvExport` has the why.
 * The query is rebuilt from the page's own URL by `objectListQuery`, the same
 * function the page's `load` uses.
 */
import { checkKey, getObject } from '#lib/server/v2/custom-objects.js';
import { forwardCsvExport } from '#lib/server/v2/csv-export.js';
import { objectListQuery } from '#lib/server/v2/object-list.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
  const key = checkKey(event.params.key);
  const definition = await getObject(event, key);
  return forwardCsvExport(
    event,
    `/objects/${key}/records/export/`,
    objectListQuery(event.url, definition.fields)
  );
};
