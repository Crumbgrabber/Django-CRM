/**
 * The API query for a custom object's list, read off the page URL. Shared by
 * the list page and its CSV export so the file holds what the page shows.
 */
import { buildFilterQuery, readFilters } from '#lib/server/v2/filter-params.js';
import { fieldKeys } from '#lib/v2/filters.js';
import { objectDescriptor, OBJECT_SEARCH_KEY } from '#lib/v2/object-filters.js';

type Fields = Parameters<typeof objectDescriptor>[0];

/** `q` (trimmed, at most 100 characters) and every valid filter; nothing else gets through. */
export function objectListQuery(url: URL, fields: Fields): URLSearchParams {
  const descriptor = objectDescriptor(fields);
  const query = buildFilterQuery(fieldKeys(descriptor), readFilters(url, descriptor));
  const q = (url.searchParams.get(OBJECT_SEARCH_KEY) ?? '').trim().slice(0, 100);
  if (q) query.set(OBJECT_SEARCH_KEY, q);
  return query;
}
