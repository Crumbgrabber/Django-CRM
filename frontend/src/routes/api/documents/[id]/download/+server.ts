/**
 * Download a document's file. See `#lib/server/v2/files.js` for why this
 * exists rather than a link straight at the file's `/media/` path.
 */
import { streamDownload } from '#lib/server/v2/files.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async (event) => {
  return streamDownload(event, `/documents/${event.params.id}/download/`);
};
