/**
 * CSV export of the invoices list page: `forwardCsvExport` has the why.
 * The query is rebuilt from the page's own URL by `invoiceListQuery`,
 * the same function the page's `load` uses.
 */
import { forwardCsvExport } from '#lib/server/v2/csv-export.js';
import { invoiceListQuery } from '#lib/server/v2/list-queries.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) => {
  return forwardCsvExport(event, '/invoices/export/', invoiceListQuery(event.url));
};
