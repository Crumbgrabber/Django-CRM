/**
 * Saved views (G29), the server half: read a person's views for one list, and
 * the three form actions (save, rename, delete) every list page spreads into
 * its own `actions`.
 *
 * It never gates. `/api/saved-views/` answers only the caller's own views
 * (another person's id is a 404) and checks every filter against what the list
 * reads, so a view built here from a hand-edited URL is refused there with a
 * 400 whose sentence is shown in the menu.
 *
 * Every action redirects back to the page URL it was posted from. The action
 * URL (`?/saveView`) replaces the query string, so without the redirect a
 * browser without JavaScript would land on the unfiltered list; with it, both
 * paths end where they started. The query comes back from a hidden input and
 * is rebuilt through `URLSearchParams` onto this page's own path, so it cannot
 * send anyone anywhere else.
 */
import { fail, redirect, type Cookies, type RequestEvent } from '@sveltejs/kit';
import { apiRequest } from '#lib/api-helpers.js';
import { apiErrorBody, apiStatus, firstMessage, type ApiErrorBody } from '#lib/api-errors.js';
import { pickFilters, type Spec } from '#lib/v2/saved-views.js';
import { readableError } from './form-errors.js';
import { FILTER_FIELDS as LEAD_FIELDS } from './leads.js';
import { FILTER_FIELDS as CONTACT_FIELDS } from './contacts.js';
import { FILTER_FIELDS as ACCOUNT_FIELDS } from './accounts.js';
import { FILTER_FIELDS as DEAL_FIELDS, BOARD_FIELDS } from './deals.js';
import { FILTER_FIELDS as TICKET_FIELDS, OPEN_STATUSES } from './tickets.js';
import { FILTER_FIELDS as INVOICE_FIELDS } from './invoices.js';
import { FILTERS } from '#lib/v2/filters.js';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/**
 * Per API list, the URL parameters its page forwards to the list under the
 * same name: the filter-bar fields plus the plain params `list-queries.js`
 * copies. Paging and the page's own presets (`inactive`, `all`, `view`) are
 * not filters and are not saved. `saved-views.test.ts` checks every key here
 * really is forwarded by the page's list query.
 */
export const SAVED_VIEW_KEYS = {
  leads: [...LEAD_FIELDS, 'search', 'rating', 'unanswered'],
  contacts: [...CONTACT_FIELDS, 'search', 'name', 'email', 'phone'],
  accounts: [...ACCOUNT_FIELDS, 'search', 'name'],
  opportunities: [...DEAL_FIELDS, 'search', 'open', 'rotten', 'pipeline'],
  cases: [...TICKET_FIELDS, 'search'],
  invoices: [...INVOICE_FIELDS]
};

/** The filter-bar page each API list is drawn on. */
const PAGE = {
  leads: 'leads',
  contacts: 'contacts',
  accounts: 'accounts',
  opportunities: 'pipeline',
  cases: 'tickets',
  invoices: 'invoices'
};

/**
 * How one page's URL maps onto a view (the `Spec` in `#lib/v2/saved-views.js`),
 * for the URL it is showing.
 *
 * `multi` is read off the filter descriptor, the same flag `readFilters` obeys,
 * so the page forwards every value of exactly these keys. The pipeline board
 * runs a narrower query than the list (`BOARD_FIELDS`), so on the board only
 * that query's keys are saved or applied, and `view` is kept so opening a
 * view does not drop the board for the list.
 *
 * @param params the page's query string
 */
export function savedViewSpec(module: keyof typeof SAVED_VIEW_KEYS, params: URLSearchParams): Spec {
  const multi = FILTERS[PAGE[module]].fields.filter((f) => f.multi).map((f) => f.key);
  if (module === 'opportunities') {
    const board = params.get('view') === 'board';
    return {
      keys: board ? [...BOARD_FIELDS, 'search', 'pipeline'] : SAVED_VIEW_KEYS.opportunities,
      multi,
      keep: ['view']
    };
  }
  if (module === 'cases') {
    return {
      keys: SAVED_VIEW_KEYS.cases,
      multi,
      implicit: { key: 'status', values: OPEN_STATUSES, allParam: 'all' }
    };
  }
  return { keys: SAVED_VIEW_KEYS[module], multi };
}

/**
 * The first message in a DRF rejection. The saved-views API writes each one as
 * a whole sentence (`{"name": ["You already have a view with this name for
 * this list."]}`), so the field name in front of it would only be noise.
 */
function firstSentence(body: ApiErrorBody | undefined): string | null {
  const first = body && typeof body === 'object' ? Object.values(body)[0] : null;
  const text = firstMessage(first);
  return typeof text === 'string' && text.trim() ? text : null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The caller's views for one list, and the page's spec, for its `load`.
 *
 * A failed fetch costs the saved-views menu, not the list under it: the same
 * degradation the tag picker gets on these pages.
 */
export async function loadSavedViews(
  { cookies, url }: { cookies: Cookies; url: URL },
  module: keyof typeof SAVED_VIEW_KEYS
) {
  const spec = savedViewSpec(module, url.searchParams);
  try {
    const resp: Schemas['SavedViewListResponse'] = await apiRequest(
      `/saved-views/?module=${module}`,
      {},
      { cookies }
    );
    return { spec, views: resp.saved_views ?? [], limit: resp.limit ?? null };
  } catch {
    return { spec, views: [], limit: null };
  }
}

/**
 * The page URL a saved-view action returns to.
 *
 * @param url the action's URL; its path is the list page's
 */
function backTo(url: URL, form: FormData) {
  const qs = new URLSearchParams(String(form.get('query') ?? '')).toString();
  return qs ? `${url.pathname}?${qs}` : url.pathname;
}

/** `saveView`, `renameView` and `deleteView` for one list page. */
export function savedViewActions(module: keyof typeof SAVED_VIEW_KEYS) {
  /** @param send makes the API call, or returns a sentence refusing it */
  async function run(
    { request, cookies, url }: RequestEvent,
    send: (form: FormData, cookies: Cookies) => Promise<unknown> | string,
    fallback: string
  ) {
    const form = await request.formData();
    const call = send(form, cookies);
    if (typeof call === 'string') return fail(400, { savedViewError: call });
    try {
      await call;
    } catch (err) {
      const status = apiStatus(err);
      if (!status) throw err;
      return fail(status === 404 ? 404 : 400, {
        savedViewError:
          status === 404
            ? 'That view no longer exists.'
            : (firstSentence(apiErrorBody(err)) ?? readableError(err, fallback))
      });
    }
    redirect(303, backTo(url, form));
  }

  const viewId = (form: FormData) => {
    const id = String(form.get('id') ?? '');
    return UUID.test(id) ? id : null;
  };

  return {
    saveView: (event: RequestEvent) =>
      run(
        event,
        (form, cookies) => {
          const name = String(form.get('name') ?? '').trim();
          if (!name) return 'Give the view a name.';
          const query = new URLSearchParams(String(form.get('query') ?? ''));
          const filters = pickFilters(query, savedViewSpec(module, query));
          return apiRequest<Schemas['SavedView']>(
            '/saved-views/',
            {
              method: 'POST',
              body: { module, name, filters } satisfies Schemas['SavedViewRequest']
            },
            { cookies }
          );
        },
        'Could not save the view.'
      ),

    renameView: (event: RequestEvent) =>
      run(
        event,
        (form, cookies) => {
          const id = viewId(form);
          const name = String(form.get('name') ?? '').trim();
          if (!id) return 'Which view?';
          if (!name) return 'Give the view a name.';
          return apiRequest<Schemas['SavedView']>(
            `/saved-views/${id}/`,
            { method: 'PATCH', body: { name } satisfies Schemas['PatchedSavedViewRequest'] },
            { cookies }
          );
        },
        'Could not rename the view.'
      ),

    deleteView: (event: RequestEvent) =>
      run(
        event,
        (form, cookies) => {
          const id = viewId(form);
          if (!id) return 'Which view?';
          return apiRequest(`/saved-views/${id}/`, { method: 'DELETE' }, { cookies });
        },
        'Could not delete the view.'
      )
  };
}
