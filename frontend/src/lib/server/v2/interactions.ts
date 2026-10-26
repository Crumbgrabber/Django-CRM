/**
 * Interactions on a record's page: the timeline read, "Log activity" and its
 * delete, over `/api/interactions/`.
 *
 * The API decides who sees what: a list holds only interactions whose home
 * record the caller can open, and a write is refused unless the caller logged
 * it or is an admin. An API older than interactions answers 404, which hides
 * the feature: the timeline keeps its notes and files and the form is not
 * offered.
 */
import { fail, type Action, type Cookies } from '@sveltejs/kit';
import { apiRequest } from '#lib/api-helpers.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { apiStatus } from '#lib/api-errors.js';
import { UUID } from '#lib/v2/custom-objects.js';
import { wallTimeToIso } from '#lib/v2/dates.js';
import {
  CALL_OUTCOMES,
  LOGGABLE_KINDS,
  durationText,
  interactionTitle,
  OUTCOME_LABEL
} from '#lib/v2/interactions.js';
import type { components } from '#lib/api-schema.js';

/** The record kinds an interaction links to, by the API's own field names. */
export const HOMES = ['lead', 'contact', 'account', 'opportunity', 'case'];

/** Origins a person's own log carries; the rest are written by the system. */
const PERSON_ORIGINS = ['manual', 'phone_tap'];
const FUTURE_SLACK_MS = 5 * 60 * 1000;

type Schemas = components['schemas'];
type Event = { cookies: Cookies };
type Interaction = ReturnType<typeof toInteraction>;
type InteractionEvent = ReturnType<typeof interactionEvents>[number];

/** The fields the pages read, rebuilt from an allow-list. */
export function toInteraction(raw: Partial<Schemas['Interaction']> | null | undefined) {
  const who = raw?.logged_by_details;
  const kind = typeof raw?.kind === 'string' ? raw.kind : '';
  const origin = typeof raw?.origin === 'string' ? raw.origin : '';
  const seconds = raw?.duration_seconds ?? null;
  return {
    id: typeof raw?.id === 'string' ? raw.id : '',
    kind,
    direction: raw?.direction === 'inbound' ? 'inbound' : 'outbound',
    occurred_at: raw?.occurred_at ?? null,
    duration_seconds: Number.isFinite(seconds) ? seconds : null,
    duration_estimated: raw?.duration_estimated === true,
    outcome: typeof raw?.outcome === 'string' ? raw.outcome : '',
    subject: typeof raw?.subject === 'string' ? raw.subject : '',
    body: typeof raw?.body === 'string' ? raw.body : '',
    logged_by: who ? who.name || who.email || null : null,
    origin,
    // Enquiries and connector rows are read-only whatever `can_edit` says.
    can_delete: raw?.can_edit === true && kind !== 'enquiry' && PERSON_ORIGINS.includes(origin)
  };
}

/**
 * A record's interactions, newest first as the API sends them. `state` is
 * `absent` on an API without interactions (any 404) and `failed` when the
 * read broke, so the page can say which.
 *
 * @param home one of HOMES
 */
export async function listInteractions(
  { cookies }: Event,
  home: string,
  id: string,
  { limit = 50 }: { limit?: number } = {}
): Promise<{ state: 'ok' | 'absent' | 'failed'; interactions: Interaction[]; count: number }> {
  if (!HOMES.includes(home) || typeof id !== 'string' || !UUID.test(id)) {
    return { state: 'failed', interactions: [], count: 0 };
  }
  const query = new URLSearchParams({ [home]: id, limit: String(limit) });
  try {
    const resp: Schemas['InteractionListResponse'] = await apiRequest(
      `/interactions/?${query}`,
      { quietErrors: true, expectedStatuses: [404] },
      { cookies }
    );
    const rows = Array.isArray(resp?.interactions) ? resp.interactions : [];
    const interactions = rows.map(toInteraction).filter((i) => i.id);
    const count = Number.isFinite(resp?.count) ? resp.count : interactions.length;
    return { state: 'ok', interactions, count };
  } catch (err) {
    return { state: apiStatus(err) === 404 ? 'absent' : 'failed', interactions: [], count: 0 };
  }
}

/**
 * Timeline events for a record page. `body` is the headline, so the deal
 * page's plain `Timeline` can show one; `detail` holds the subject and note.
 */
export function interactionEvents(interactions: Interaction[]) {
  return interactions.map((i) => {
    const facts = [interactionTitle(i)];
    if (i.kind === 'call' && OUTCOME_LABEL[i.outcome]) facts.push(OUTCOME_LABEL[i.outcome]);
    const length = durationText(i.duration_seconds, i.duration_estimated);
    if (length) facts.push(length);
    return {
      id: `ix-${i.id}`,
      type: 'interaction' as const,
      kind: i.kind,
      direction: i.direction,
      at: i.occurred_at,
      by: i.logged_by,
      body: facts.join(' · '),
      detail: [i.subject, i.body].filter(Boolean).join('\n\n'),
      interaction: i.id,
      canDelete: i.can_delete
    };
  });
}

/** `new Date(at)` for an `at` that may be missing: null is the epoch, undefined no time. */
const timeOf = (at: string | null | undefined) =>
  at === undefined ? NaN : new Date(at ?? 0).getTime();

/**
 * A page's activity with the interactions merged in, newest first.
 *
 * @param activity events carrying `at`
 */
export function withInteractions<A extends { at?: string | null }>(
  activity: A[],
  interactions: Interaction[]
): Array<A | InteractionEvent> {
  return [...activity, ...interactionEvents(interactions)].sort(
    (a, b) => timeOf(b.at) - timeOf(a.at)
  );
}

/**
 * The request body for a log from the form, or an Error whose message is the
 * sentence to show. Only allow-listed keys are built, and the home comes from
 * the route, never the form.
 *
 * @param home one of HOMES
 * @param values the form's fields
 */
export function interactionBody(
  home: string,
  id: string,
  values: Record<string, string | undefined>,
  { timeZone = 'UTC', now = new Date() }: { timeZone?: string; now?: Date } = {}
) {
  if (!HOMES.includes(home) || typeof id !== 'string' || !UUID.test(id)) {
    throw new Error('That record does not exist.');
  }
  const kind = String(values.kind ?? '');
  if (!LOGGABLE_KINDS.includes(kind)) throw new Error('Choose what you are logging.');

  const body: Record<string, string | number | boolean> = {
    kind,
    direction: kind !== 'meeting' && values.direction === 'inbound' ? 'inbound' : 'outbound',
    origin: 'manual',
    [home]: id
  };

  const outcome = String(values.outcome ?? '');
  if (kind === 'call' && outcome) {
    if (!CALL_OUTCOMES.includes(outcome)) throw new Error('Choose how the call went.');
    body.outcome = outcome;
  }

  const minutes = String(values.duration_minutes ?? '').trim();
  if (minutes && (kind === 'call' || kind === 'meeting')) {
    const n = Number(minutes);
    if (!Number.isInteger(n) || n < 0) throw new Error('Duration is a whole number of minutes.');
    body.duration_seconds = n * 60;
    body.duration_estimated = false;
  }

  const subject = String(values.subject ?? '').trim();
  if (subject && (kind === 'email' || kind === 'meeting')) {
    if (subject.length > 200) throw new Error('The subject is longer than 200 characters.');
    body.subject = subject;
  }

  const note = String(values.body ?? '').trim();
  if (note.length > 10000) throw new Error('The note is longer than 10,000 characters.');
  if (note) body.body = note;

  const when = String(values.occurred_at ?? '').trim();
  if (when) {
    const iso = wallTimeToIso(when, timeZone);
    if (!iso) throw new Error('That date and time could not be read.');
    if (new Date(iso).getTime() > now.getTime() + FUTURE_SLACK_MS) {
      throw new Error('That time is in the future.');
    }
    body.occurred_at = iso;
  }
  return body;
}

export async function logInteraction(
  { cookies }: Event,
  body: ReturnType<typeof interactionBody>
): Promise<Schemas['Interaction']> {
  return await apiRequest('/interactions/', { method: 'POST', body }, { cookies });
}

export async function deleteInteraction({ cookies }: Event, id: string) {
  if (typeof id !== 'string' || !UUID.test(id)) {
    throw Object.assign(new Error('That activity does not exist.'), { status: 404 });
  }
  return await apiRequest(`/interactions/${id}/`, { method: 'DELETE' }, { cookies });
}

const refusalCode = (err: unknown) => {
  const status = apiStatus(err);
  return status !== undefined && [400, 403, 404].includes(status) ? status : 400;
};

/**
 * The two form actions a record page spreads in: `logActivity` and
 * `deleteActivity`. Results and errors travel under `form.activity`.
 *
 * @param home one of HOMES
 */
export function interactionActions(home: string): { logActivity: Action; deleteActivity: Action } {
  return {
    logActivity: async (event) => {
      const form = await event.request.formData();
      const values: Record<string, string> = {};
      for (const key of [
        'kind',
        'direction',
        'outcome',
        'duration_minutes',
        'subject',
        'body',
        'occurred_at'
      ]) {
        values[key] = form.get(key)?.toString() ?? '';
      }
      const timeZone = event.locals?.org_settings?.timezone || 'UTC';
      let body;
      try {
        body = interactionBody(home, event.params.id ?? '', values, { timeZone });
      } catch (err) {
        return fail(400, { activity: { error: err instanceof Error ? err.message : String(err) } });
      }
      try {
        await logInteraction(event, body);
      } catch (err) {
        return fail(refusalCode(err), {
          activity: { error: readableError(err, 'Could not log that.') }
        });
      }
      return { activity: { logged: true } };
    },
    deleteActivity: async (event) => {
      const form = await event.request.formData();
      try {
        await deleteInteraction(event, form.get('interaction')?.toString() ?? '');
      } catch (err) {
        return fail(refusalCode(err), {
          activity: { deleteError: readableError(err, 'Could not delete that activity.') }
        });
      }
      return { activity: { deleted: true } };
    }
  };
}
