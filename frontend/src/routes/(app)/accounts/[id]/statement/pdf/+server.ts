import { forwardStatementPdf } from '#lib/server/v2/statements.js';
import type { RequestHandler } from './$types';

/**
 * The statement as a PDF, for the period in the query string. The API decides
 * who may have it; `forwardStatementPdf` has the why.
 */
export const GET: RequestHandler = (event) => {
  return forwardStatementPdf(event);
};
