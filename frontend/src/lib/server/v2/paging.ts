/**
 * Page position for the list pages, read from the URL.
 *
 * `offset` and `limit` are the API's own LimitOffsetPagination parameters.
 * Both are clamped here so a hand-typed `?limit=100000` or `?offset=-5` never
 * reaches Django. Server-only, like `list-queries.ts`.
 */
export const PAGE_SIZES = [25, 50, 100] as const;
export const DEFAULT_PAGE_SIZE = 25;

export function readPaging(url: URL) {
  const rawLimit = Math.floor(Number(url.searchParams.get('limit')));
  const limit = (PAGE_SIZES as readonly number[]).includes(rawLimit) ? rawLimit : DEFAULT_PAGE_SIZE;
  const rawOffset = Math.floor(Number(url.searchParams.get('offset')));
  const offset = Number.isFinite(rawOffset) && rawOffset > 0 ? rawOffset : 0;
  return { limit, offset };
}

/** Sets the clamped `limit` and `offset` on a query. */
export function withPaging(params: URLSearchParams, url: URL) {
  const { limit, offset } = readPaging(url);
  params.set('limit', String(limit));
  if (offset) params.set('offset', String(offset));
  else params.delete('offset');
  return params;
}
