import { search } from '#lib/server/v2/search.js';
import type { RequestHandler } from './$types';

/**
 * ⌘K palette search. The palette runs in the browser and the access token is an
 * httpOnly cookie, so the query is proxied through here; the cookie stays
 * server-side and the Django endpoint scopes results to the caller's org.
 */
export const GET: RequestHandler = async ({ url, cookies }) => {
  const q = url.searchParams.get('q') || '';
  try {
    return Response.json(await search({ cookies }, q));
  } catch (err) {
    const message = (err as { message?: unknown } | null | undefined)?.message;
    return Response.json({ results: [], error: message || 'Search failed' }, { status: 400 });
  }
};
