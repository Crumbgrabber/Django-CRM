/**
 * Global search for the ⌘K palette, the wiring behind /api/search.
 *
 * Server-only. One org-scoped backend call, `GET /search/`, returns typed hits
 * across every module (the org comes from the JWT, never the client, and each
 * type is already filtered to what the caller may open). This layer only maps
 * the backend `type` to the palette's group label and the detail route to open.
 */
import { apiRequest } from '#lib/api-helpers.js';
import type { Cookies } from '@sveltejs/kit';
import { recordHref } from '#lib/v2/custom-objects.js';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];
// `group` is required in the generated hit; an API from before the release
// window omits it, so the mapper accepts a hit without one.
type SearchHitWithGroup = Omit<Schemas['GlobalSearchHit'], 'group'> & { group?: string };
export type SearchHit = { kind: string; id: string; title: string; meta: string; href: string };

/** Backend `type` → palette group label + detail route. */
const MAP = {
  lead: { kind: 'Leads', href: (id: string) => `/leads/${id}` },
  deal: { kind: 'Deals', href: (id: string) => `/pipeline/${id}` },
  account: { kind: 'Accounts', href: (id: string) => `/accounts/${id}` },
  contact: { kind: 'Contacts', href: (id: string) => `/contacts/${id}` },
  ticket: { kind: 'Tickets', href: (id: string) => `/tickets/${id}` },
  invoice: { kind: 'Invoices', href: (id: string) => `/invoices/${id}` },
  solution: {
    kind: 'Knowledge base',
    href: (id: string) => `/solutions/${id}`
  }
};

/** One backend hit as a palette row, or null for a type this app cannot open. */
export function paletteHit(r: SearchHitWithGroup): SearchHit | null {
  const builtIn = Object.hasOwn(MAP, r.type) ? MAP[r.type as keyof typeof MAP] : null;
  const href = builtIn ? builtIn.href(r.id) : recordHref(r.type, r.id);
  if (!href) return null;
  const kind = r.group || builtIn?.kind || (r.type.startsWith('obj:') ? 'Records' : '');
  return { kind, id: r.id, title: r.title, meta: r.subtitle || '', href };
}

/**
 * Org-scoped search, shaped for the palette (`{ kind, id, title, meta, href }`).
 * The two-character floor matches the backend's, so a one-character query never
 * makes a round trip.
 */
export async function search(
  { cookies }: { cookies: Cookies },
  q: string
): Promise<{ results: SearchHit[] }> {
  const query = (q || '').trim();
  if (query.length < 2) return { results: [] };

  const data: Schemas['GlobalSearchResponse'] = await apiRequest(
    `/search/?q=${encodeURIComponent(query)}`,
    {},
    { cookies }
  );

  const results = (data.results || [])
    .map(paletteHit)
    .filter((hit): hit is SearchHit => hit !== null);

  return { results };
}
