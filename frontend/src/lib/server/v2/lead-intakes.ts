/**
 * Lead webhooks: the wiring behind the webhooks half of `/settings/lead-capture`.
 *
 * Admin-only, reads included (`/api/leads/intakes/` answers a member 403), so
 * the list folds a 403 into `forbidden`. An API older than intakes answers
 * 404, which hides the webhooks part of the page.
 *
 * THE KEY
 * The full key travels in exactly two responses, a create and a replace, and
 * goes to the page for that one render. Every read is rebuilt from an
 * allow-list that leaves `key` out, so a detail page can only ever show
 * `key_hint`, even if a response starts carrying more.
 */
import { error, type Cookies } from '@sveltejs/kit';
import { apiRequest, type FormBody } from '#lib/api-helpers.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';
import { rethrowModuleOff } from '#lib/server/v2/modules.js';
import { viewerIsAdmin } from '#lib/server/v2/organization.js';
import { UUID } from '#lib/v2/custom-objects.js';
import { cleanMapping } from '#lib/v2/lead-intakes.js';
import type { components } from '#lib/api-schema.js';

const INTAKE_GONE = 'That webhook does not exist.';

type Event = { cookies: Cookies };
type Schemas = components['schemas'];

/** A list read off any of the shapes a DRF list view answers with. */
function listOf<T>(
  resp: Record<string, T[] | undefined> | T[] | null | undefined,
  key: string
): T[] {
  if (Array.isArray(resp)) return resp;
  const listed = resp?.[key];
  if (Array.isArray(listed)) return listed;
  return Array.isArray(resp?.results) ? resp.results : [];
}

/** @param value an id, or an object carrying one */
function idOf(value: unknown) {
  if (typeof value === 'string') return value;
  return value && typeof value === 'object' && 'id' in value && typeof value.id === 'string'
    ? value.id
    : null;
}

/** The fields the pages read. `key` is deliberately not among them. */
export function toIntake(raw: Schemas['LeadIntake'] | null | undefined) {
  const owner = raw?.assignee_details;
  return {
    id: raw?.id ?? '',
    name: raw?.name ?? '',
    preset: raw?.preset ?? 'generic',
    url: raw?.url ?? '',
    key_hint: raw?.key_hint ?? '',
    mapping: cleanMapping(raw?.mapping),
    default_source: raw?.default_source ?? '',
    source_detail: raw?.source_detail ?? '',
    tags: (Array.isArray(raw?.tags) ? raw.tags : []).map(idOf).filter(Boolean),
    assignee: idOf(raw?.assignee),
    // The name for an owner the people picker no longer lists (deactivated).
    assignee_name: owner?.name || owner?.email || null,
    is_active: raw?.is_active !== false,
    last_received_at: raw?.last_received_at ?? null,
    last_error: raw?.last_error ?? '',
    created_at: raw?.created_at ?? null
  };
}

function toDelivery(raw: Schemas['LeadIntakeDelivery'] | null | undefined) {
  return {
    id: raw?.id ?? '',
    received_at: raw?.received_at ?? null,
    result: raw?.result ?? '',
    lead: idOf(raw?.lead),
    external_id: raw?.external_id ?? '',
    error: raw?.error ?? ''
  };
}

function checkId(id: string) {
  if (typeof id !== 'string' || !UUID.test(id)) error(404, INTAKE_GONE);
  return id;
}

export async function listIntakes({ cookies }: Event): Promise<{
  state: 'ok' | 'forbidden' | 'absent' | 'failed';
  intakes: ReturnType<typeof toIntake>[];
}> {
  try {
    const resp: Schemas['LeadIntakeListResponse'] = await apiRequest(
      '/leads/intakes/',
      { expectedStatuses: [403, 404] },
      { cookies }
    );
    return { state: 'ok', intakes: listOf(resp, 'intakes').map(toIntake) };
  } catch (err) {
    if (apiStatus(err) === 403) return { state: 'forbidden', intakes: [] };
    if (apiStatus(err) === 404) return { state: 'absent', intakes: [] };
    return { state: 'failed', intakes: [] };
  }
}

/**
 * One intake and its newest deliveries (the API keeps 50). The deliveries are
 * best-effort: a failed read leaves the settings usable.
 */
export async function getIntake(
  { cookies }: Event,
  id: string
): Promise<
  | { forbidden: true }
  | {
      forbidden: false;
      intake: ReturnType<typeof toIntake>;
      deliveries: ReturnType<typeof toDelivery>[];
      deliveriesFailed: boolean;
    }
> {
  checkId(id);
  const detailRead: Promise<Schemas['LeadIntake']> = apiRequest(
    `/leads/intakes/${id}/`,
    { expectedStatuses: [403, 404] },
    { cookies }
  );
  const deliveriesRead: Promise<Schemas['LeadIntakeDeliveriesResponse']> = apiRequest(
    `/leads/intakes/${id}/deliveries/`,
    { quietErrors: true },
    { cookies }
  );
  const [detail, deliveries] = await Promise.all([
    detailRead.catch((err) => {
      if (apiStatus(err) === 403) return null;
      rethrowModuleOff(err);
      if (apiStatus(err) === 404) error(404, INTAKE_GONE);
      throw err;
    }),
    deliveriesRead.then(
      (resp) =>
        listOf(resp, 'deliveries')
          .map(toDelivery)
          .sort((a, b) => String(b.received_at).localeCompare(String(a.received_at))),
      () => null
    )
  ]);
  if (detail === null) return { forbidden: true };
  return {
    forbidden: false,
    intake: toIntake(detail),
    deliveries: deliveries ?? [],
    deliveriesFailed: deliveries === null
  };
}

/** The fields an admin edits. `key`, `url`, `id` and the org never go up. */
const WRITABLE: (keyof Schemas['LeadIntakeRequest'])[] = [
  'name',
  'preset',
  'mapping',
  'default_source',
  'source_detail',
  'tags',
  'assignee',
  'is_active'
];

export function intakeBody(values: Record<string, unknown>) {
  const body: FormBody<Schemas['LeadIntakeRequest']> = {};
  for (const key of WRITABLE) {
    if (values[key] !== undefined) body[key] = values[key];
  }
  if (body.name !== undefined) {
    body.name = String(body.name).trim();
    if (!body.name) throw new Error('A webhook needs a name.');
  }
  if (body.mapping !== undefined) body.mapping = cleanMapping(body.mapping);
  if (body.tags !== undefined) {
    body.tags = (Array.isArray(body.tags) ? body.tags : []).map(String).filter(Boolean);
  }
  if (body.assignee !== undefined) body.assignee = body.assignee || null;
  if (body.is_active !== undefined) body.is_active = body.is_active === true;
  for (const key of ['default_source', 'source_detail'] as const) {
    if (body[key] !== undefined) body[key] = String(body[key] ?? '').trim();
  }
  return body;
}

/**
 * Returns the one response that carries the full key, cut to what the page
 * shows once: where to post and with what.
 */
export async function createIntake({ cookies }: Event, values: Record<string, unknown>) {
  const body = intakeBody(values);
  if (!body.name) throw new Error('A webhook needs a name.');
  const resp: Schemas['LeadIntakeKeyed'] = await apiRequest(
    '/leads/intakes/',
    { method: 'POST', body },
    { cookies }
  );
  return {
    id: resp?.id ?? '',
    name: resp?.name ?? String(body.name),
    url: resp?.url ?? '',
    key: typeof resp?.key === 'string' ? resp.key : ''
  };
}

export async function updateIntake(
  { cookies }: Event,
  id: string,
  values: Record<string, unknown>
): Promise<Schemas['LeadIntake']> {
  checkId(id);
  return await apiRequest(
    `/leads/intakes/${id}/`,
    { method: 'PATCH', body: intakeBody(values) },
    { cookies }
  );
}

export async function deleteIntake({ cookies }: Event, id: string) {
  checkId(id);
  return await apiRequest(`/leads/intakes/${id}/`, { method: 'DELETE' }, { cookies });
}

/** A new key, answered once. The old one keeps working for 7 days server-side. */
export async function replaceIntakeKey({ cookies }: Event, id: string): Promise<{ key: string }> {
  checkId(id);
  const resp: Schemas['LeadIntakeKeyed'] = await apiRequest(
    `/leads/intakes/${id}/key/`,
    { method: 'POST' },
    { cookies }
  );
  return { key: typeof resp?.key === 'string' ? resp.key : '' };
}

/** Logs a `test` delivery and makes no lead. */
export async function testIntake(
  { cookies }: Event,
  id: string
): Promise<Schemas['LeadIntakeTestResponse']> {
  checkId(id);
  return await apiRequest(`/leads/intakes/${id}/test/`, { method: 'POST' }, { cookies });
}

/**
 * The settings hub's numbers, asked only for an admin (a member is refused).
 * Null when they cannot be read, false when the API has no intakes.
 */
export async function intakesSummary({
  cookies
}: Event): Promise<{ count: number; active: number } | null | false> {
  if (!viewerIsAdmin(cookies)) return null;
  try {
    const resp: Schemas['LeadIntakeListResponse'] = await apiRequest(
      '/leads/intakes/',
      { quietErrors: true, expectedStatuses: [403, 404] },
      { cookies }
    );
    const rows = listOf(resp, 'intakes');
    return { count: rows.length, active: rows.filter((r) => r?.is_active !== false).length };
  } catch (err) {
    return apiStatus(err) === 404 && apiErrorBody(err)?.code !== 'module_off' ? false : null;
  }
}
