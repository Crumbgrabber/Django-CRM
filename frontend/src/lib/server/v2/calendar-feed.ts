/**
 * Your task calendar feed: the wiring behind `/profile/calendar-feed`.
 *
 * Server-only, because the feed URL is a credential: anyone holding it can read
 * the titles and priorities of your open tasks. `/api/profile/calendar-feed/`
 * is self-scoped server-side (`profile=request.profile`) and refuses every
 * API token, so this page can only ever manage the signed-in member's own feed.
 *
 * - `GET`    `{ enabled, created_at, last_used_at }`. Never the URL: the API
 *            keeps only a hash of it.
 * - `POST`   turns the feed on, or replaces it. The old URL stops working and
 *            the response carries the new `url`, the one time it is shown.
 * - `DELETE` turns it off. The URL stops working.
 */
import { apiRequest } from '#lib/api-helpers.js';
import type { Cookies } from '@sveltejs/kit';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

const ENDPOINT = '/profile/calendar-feed/';

export async function getCalendarFeed({
  cookies
}: {
  cookies: Cookies;
}): Promise<{ enabled: boolean; created_at: string | null; last_used_at: string | null }> {
  const resp: Schemas['CalendarFeedStateResponse'] = await apiRequest(ENDPOINT, {}, { cookies });
  return {
    enabled: Boolean(resp?.enabled),
    created_at: resp?.created_at ?? null,
    last_used_at: resp?.last_used_at ?? null
  };
}

/** Issue a new feed URL. Returns it; it cannot be read back afterwards. */
export async function issueCalendarFeed({ cookies }: { cookies: Cookies }): Promise<string> {
  const resp: Schemas['CalendarFeedIssuedResponse'] = await apiRequest(
    ENDPOINT,
    { method: 'POST' },
    { cookies }
  );
  return resp.url;
}

export function disableCalendarFeed({
  cookies
}: {
  cookies: Cookies;
}): Promise<Schemas['CalendarFeedStateResponse']> {
  return apiRequest(ENDPOINT, { method: 'DELETE' }, { cookies });
}
