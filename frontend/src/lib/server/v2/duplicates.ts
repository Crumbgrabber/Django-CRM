/**
 * Possible duplicates and merging, for leads, contacts and accounts (G19).
 *
 * Three API calls, the same for each module:
 *
 *   POST /api/<module>/duplicates/             while a create form is typed
 *   GET  /api/<module>/<id>/duplicates/        the detail page's panel
 *   POST /api/<module>/<keeper>/merge/         {"merge_id": "<loser>"}
 *
 * The API decides everything that matters: it searches only the records the
 * caller may open, so nothing here can show or count a hidden one, and it
 * refuses a merge the caller may not make whatever this layer or the page
 * believed. `can_delete` on each hit is a hint for the page, not a gate.
 */
import { error, fail, redirect, type Cookies } from '@sveltejs/kit';
import { apiRequest } from '#lib/api-helpers.js';
import { apiStatus } from '#lib/api-errors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import type { components } from '#lib/api-schema.js';

type Schemas = components['schemas'];

/** A record off its detail endpoint; the three modules' bodies differ. */
type MergeRecord = Record<string, unknown>;

const text = (value: unknown) => (typeof value === 'string' ? value : undefined);

/**
 * The modules that have duplicates, the query fields each one's create form
 * may send, and what the compare page shows side by side.
 */
export const DUPLICATE_MODULES: Record<
  string,
  {
    singular: string;
    record: string;
    query: (keyof Schemas['DuplicateQueryRequest'])[];
    compare: Array<[string, (o: MergeRecord) => string | undefined]>;
  }
> = {
  leads: {
    singular: 'lead',
    record: 'lead_obj',
    query: ['email', 'phone', 'first_name', 'last_name', 'company_name'],
    compare: [
      ['Name', (o) => personName(o)],
      ['Company', (o) => text(o.company_name)],
      ['Email', (o) => text(o.email)],
      ['Phone', (o) => text(o.phone)],
      ['Website', (o) => text(o.website)],
      ['Status', (o) => text(o.status)],
      ['Created', (o) => text(o.created_at)?.slice(0, 10)]
    ]
  },
  contacts: {
    singular: 'contact',
    record: 'contact_obj',
    query: ['email', 'phone', 'first_name', 'last_name'],
    compare: [
      ['Name', (o) => personName(o)],
      ['Job title', (o) => text(o.title)],
      ['Company', (o) => text(o.organization)],
      ['Email', (o) => text(o.email)],
      ['Phone', (o) => text(o.phone)],
      ['City', (o) => text(o.city)],
      ['Created', (o) => text(o.created_at)?.slice(0, 10)]
    ]
  },
  accounts: {
    singular: 'account',
    record: 'account_obj',
    query: ['name', 'email', 'phone', 'website'],
    compare: [
      ['Name', (o) => text(o.name)],
      ['Website', (o) => text(o.website)],
      ['Email', (o) => text(o.email)],
      ['Phone', (o) => text(o.phone)],
      ['Industry', (o) => text(o.industry)],
      ['City', (o) => text(o.city)],
      ['Created', (o) => text(o.created_at)?.slice(0, 10)]
    ]
  }
};

function personName(o: MergeRecord) {
  return [o.first_name, o.last_name].filter(Boolean).join(' ');
}

type MergeModule = 'leads' | 'contacts' | 'accounts';

function spec(module: string) {
  // `Object.hasOwn`, so `__proto__` or `constructor` is not a module.
  if (!Object.hasOwn(DUPLICATE_MODULES, module)) error(404, 'Not found');
  return DUPLICATE_MODULES[module];
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * An id about to become part of an API path, or a 404.
 *
 * `?with=` and the merge form's fields come from the browser. Built into a
 * path unchecked, `../..` would walk this server's authenticated request to
 * any API route the caller's token reaches, so only a UUID gets through.
 */
function recordId(value: unknown): string {
  if (typeof value !== 'string' || !UUID.test(value)) error(404, 'Not found');
  return value;
}

/**
 * "email and phone", for "shares their email and phone". The API names each
 * rule in plain words already (`email`, `phone`, `name`, `company`,
 * `website`), so this only joins them.
 */
export function matchedLabel(reasons: string[]) {
  const words = reasons ?? [];
  if (words.length <= 1) return words.join('');
  return `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`;
}

export type DuplicateMatch = ReturnType<typeof toHit>;

function toHit(hit: Schemas['DuplicateHit']) {
  return {
    id: hit.id,
    name: hit.name,
    email: hit.email ?? '',
    phone: hit.phone ?? '',
    matched_on: matchedLabel(hit.matched_on),
    can_delete: Boolean(hit.can_delete)
  };
}

/**
 * Possible duplicates of a record being typed into a create form. Only the
 * module's own fields are forwarded, and blank ones are dropped. A POST body,
 * never a query string: an email and a phone in a URL are written to every
 * access log on the way.
 */
export async function checkDuplicates(
  { cookies }: { cookies: Cookies },
  module: string,
  criteria: Record<string, unknown>
) {
  const body: Schemas['DuplicateQueryRequest'] = {};
  for (const field of spec(module).query) {
    const value = criteria?.[field];
    if (typeof value === 'string' && value.trim()) body[field] = value.trim();
  }
  if (!Object.keys(body).length) return [];
  const response: Schemas['DuplicatesResponse'] = await apiRequest(
    `/${module}/duplicates/`,
    { method: 'POST', body },
    { cookies }
  );
  return (response?.duplicates ?? []).map(toHit);
}

/**
 * Possible duplicates of a saved record, for its detail page. A failed check
 * is not a reason to fail the page, so it answers "none" instead.
 */
export async function recordDuplicates(
  { cookies }: { cookies: Cookies },
  module: string,
  id: string
) {
  spec(module);
  recordId(id);
  try {
    const response: Schemas['RecordDuplicatesResponse'] = await apiRequest(
      `/${module}/${id}/duplicates/`,
      {},
      { cookies }
    );
    return {
      can_delete: Boolean(response?.can_delete),
      duplicates: (response?.duplicates ?? []).map(toHit)
    };
  } catch {
    return { can_delete: false, duplicates: [] };
  }
}

/**
 * The two records of a merge, side by side. Both come from their detail
 * endpoint, so either one the caller may not open is the same 404 as a
 * missing id.
 */
export async function getMergePair(
  { cookies }: { cookies: Cookies },
  module: MergeModule,
  id: string,
  otherId: string | null
) {
  const { singular, record, compare } = spec(module);
  recordId(id);
  if (!otherId || otherId === id) error(404, `Pick the ${singular} to compare this one with.`);
  recordId(otherId);

  const load = async (pk: string) => {
    try {
      const detailCall: Promise<Record<string, unknown>> = apiRequest(
        `/${module}/${pk}/`,
        {},
        { cookies }
      );
      const dupsCall: Promise<Schemas['RecordDuplicatesResponse']> = apiRequest(
        `/${module}/${pk}/duplicates/`,
        {},
        { cookies }
      );
      const [detail, dups] = await Promise.all([
        detailCall,
        // Only for `can_delete`. If it fails the page still loads, and that
        // record is simply not offered as the one to merge away.
        dupsCall.catch(() => null)
      ]);
      const obj = detail[record] as MergeRecord;
      return {
        id: obj.id as string,
        name:
          record === 'account_obj'
            ? (obj.name as string)
            : personName(obj) || text(obj.email) || singular,
        can_delete: Boolean(dups?.can_delete),
        fields: compare.map(([label, read]) => ({ label, value: read(obj) || '' }))
      };
    } catch (err) {
      if (apiStatus(err) === 404) {
        error(404, `That ${singular} does not exist, or you do not have access to it.`);
      }
      throw err;
    }
  };

  const [current, other] = await Promise.all([load(id), load(otherId)]);
  return { module, singular, current, other };
}

/**
 * Merge `loserId` into `keeperId`. The API checks both records and the
 * caller's rights on each; a refusal arrives as a thrown error with its status.
 */
export async function mergeRecords(
  { cookies }: { cookies: Cookies },
  module: MergeModule,
  keeperId: string,
  loserId: string
): Promise<Schemas['MergeResponse']> {
  spec(module);
  recordId(keeperId);
  recordId(loserId);
  return await apiRequest(
    `/${module}/${keeperId}/merge/`,
    { method: 'POST', body: { merge_id: loserId } satisfies Schemas['MergeRequestRequest'] },
    { cookies }
  );
}

/**
 * `load` and the `merge` action for `/<module>/<id>/merge?with=<other>`, the
 * side-by-side page where the person picks which record to keep. The three
 * routes are one line each on top of this.
 *
 * The two ids arrive in the form rather than the query string, because a
 * form action posts to `?/merge` and drops `?with=`. Whichever the form says,
 * the keeper must be one of the two records on the page and the loser is the
 * other one; the API re-checks both.
 */
export function mergeRoute(module: MergeModule) {
  return {
    load: async ({
      cookies,
      params,
      url
    }: {
      cookies: Cookies;
      params: Record<string, string>;
      url: URL;
    }) => getMergePair({ cookies }, module, params.id, url.searchParams.get('with')),

    actions: {
      merge: async ({
        cookies,
        params,
        request
      }: {
        cookies: Cookies;
        params: Record<string, string>;
        request: Request;
      }) => {
        const form = await request.formData();
        const other = form.get('other')?.toString() ?? '';
        const keep = form.get('keep')?.toString() ?? '';
        const pair = [params.id, other];
        if (!UUID.test(params.id) || !UUID.test(other) || other === params.id) {
          return fail(404, { error: 'Not found' });
        }
        if (!pair.includes(keep)) {
          return fail(400, { error: 'Choose which record to keep.' });
        }
        if (form.get('confirm') !== 'on') {
          return fail(400, { error: 'Tick the box to confirm the other record will be deleted.' });
        }
        const loser = keep === params.id ? other : params.id;
        try {
          await mergeRecords({ cookies }, module, keep, loser);
        } catch (err) {
          const status = apiStatus(err);
          return fail(status === 404 || status === 403 ? status : 400, {
            error: readableError(err, 'Could not merge these records.')
          });
        }
        redirect(303, `/${module}/${keep}`);
      }
    }
  };
}
