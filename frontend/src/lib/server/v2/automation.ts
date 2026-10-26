/**
 * The automation builder's API, behind `/settings/automation`. Server-only.
 * The contract is the code in `backend/automation/`.
 */
import { error, fail, type Cookies } from '@sveltejs/kit';
import { apiRequest } from '#lib/api-helpers.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { checkId } from '#lib/server/v2/custom-objects.js';
import { isPlanRefusal } from '#lib/server/v2/billing.js';
import type { components } from '#lib/api-schema.js';

export const RULE_GONE = 'That rule does not exist, or you do not have access to it.';
// The hosted web app can run ahead of its API during a release, so an API
// without these routes reads as "not offered", as custom objects do.
export const NOT_AVAILABLE = 'Automation rules are not available here.';
const UNREADABLE = 'Could not read the rule.';

/** Runs per page on a rule's history. */
export const RUN_PAGE = 20;

type Event = { cookies: Cookies };
type Schemas = components['schemas'];

export async function getCatalogue({
  cookies
}: Event): Promise<Schemas['AutomationCatalogueResponse']> {
  try {
    return await apiRequest(
      '/automation/catalogue/',
      { expectedStatuses: [403, 404] },
      { cookies }
    );
  } catch (err) {
    if (apiStatus(err) === 404) error(404, NOT_AVAILABLE);
    throw err;
  }
}

export async function listRules({
  cookies
}: Event): Promise<
  | { forbidden: true }
  | { forbidden?: undefined; summary: string | null; rules: Schemas['RuleRow'][] }
> {
  try {
    const resp: Schemas['AutomationRuleListResponse'] = await apiRequest(
      '/automation/rules/',
      { expectedStatuses: [403, 404] },
      { cookies }
    );
    return { summary: resp?.summary ?? null, rules: resp?.results ?? [] };
  } catch (err) {
    if (apiStatus(err) === 403) return { forbidden: true };
    if (apiStatus(err) === 404) error(404, NOT_AVAILABLE);
    throw err;
  }
}

export async function getRule({ cookies }: Event, id: string): Promise<Schemas['Rule']> {
  checkId(id);
  try {
    return await apiRequest(
      `/automation/rules/${id}/`,
      { expectedStatuses: [403, 404] },
      { cookies }
    );
  } catch (err) {
    if (apiStatus(err) === 404) error(404, RULE_GONE);
    throw err;
  }
}

export async function createRule(
  { cookies }: Event,
  body: Record<string, unknown>
): Promise<Schemas['Rule']> {
  return await apiRequest('/automation/rules/', { method: 'POST', body }, { cookies });
}

export async function updateRule(
  { cookies }: Event,
  id: string,
  body: Record<string, unknown>
): Promise<Schemas['Rule']> {
  checkId(id);
  return await apiRequest(`/automation/rules/${id}/`, { method: 'PATCH', body }, { cookies });
}

export async function switchOff(event: Event, id: string) {
  return await updateRule(event, id, { is_active: false });
}

export async function deleteRule({ cookies }: Event, id: string) {
  checkId(id);
  await apiRequest(`/automation/rules/${id}/`, { method: 'DELETE' }, { cookies });
}

export async function tryRule(
  { cookies }: Event,
  id: string,
  recordId: string
): Promise<Schemas['AutomationStep'][]> {
  checkId(id);
  const resp: Schemas['AutomationRuleTryResponse'] = await apiRequest(
    `/automation/rules/${id}/try/`,
    { method: 'POST', body: { record_id: recordId } },
    { cookies }
  );
  return resp?.steps ?? [];
}

export async function listRuns({ cookies }: Event, id: string, rawOffset: number) {
  checkId(id);
  const whole = Math.trunc(Number(rawOffset));
  const offset = Number.isSafeInteger(whole) ? Math.max(0, whole) : 0;
  const resp: Schemas['AutomationRunListResponse'] = await apiRequest(
    `/automation/rules/${id}/runs/?limit=${RUN_PAGE}&offset=${offset}`,
    {},
    { cookies }
  );
  return { count: resp?.count ?? 0, runs: resp?.results ?? [], offset, pageSize: RUN_PAGE };
}

export async function reorderRules(
  { cookies }: Event,
  ids: string[]
): Promise<Schemas['AutomationRuleReorderResponse']> {
  return await apiRequest(
    '/automation/rules/reorder/',
    { method: 'POST', body: { ids } },
    { cookies }
  );
}

/**
 * The Settings row's numbers. Null when they cannot be read, so the row shows
 * without them; false when the API has no automation, so the row is hidden.
 */
export async function automationSummary({
  cookies
}: Event): Promise<{ active: number; failing: number; attention: boolean } | null | false> {
  try {
    const resp: Schemas['AutomationRuleListResponse'] = await apiRequest(
      '/automation/rules/',
      { quietErrors: true },
      { cookies }
    );
    const rules = Array.isArray(resp?.results) ? resp.results : [];
    let active = 0;
    let failing = 0;
    let attention = false;
    for (const r of rules) {
      const bad = r.failures_7d > 0 || r.status === 'needs_attention';
      if (r.is_active) active += 1;
      if (bad) failing += 1;
      if (bad || r.status === 'paused') attention = true;
    }
    return { active, failing, attention };
  } catch (err) {
    return apiStatus(err) === 404 ? false : null;
  }
}

/** Parsed JSON as an object, or the unreadable-rule error. */
function record(source: unknown): Record<string, unknown> {
  if (source === null || typeof source !== 'object' || Array.isArray(source)) {
    throw new Error(UNREADABLE);
  }
  return source as Record<string, unknown>;
}

function pick(source: unknown, keys: string[]) {
  const from = record(source);
  const out: Record<string, unknown> = {};
  for (const key of keys) if (Object.hasOwn(from, key)) out[key] = from[key];
  return out;
}

function list(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error(UNREADABLE);
  return value;
}

const ACTION_KEYS: Record<string, string[]> = {
  set_field: ['target', 'field', 'value'],
  assign: ['mode', 'people'],
  create_task: ['title', 'due_in_days', 'priority', 'assign_to', 'person'],
  notify: ['to', 'people', 'message'],
  webhook: ['endpoint']
};

/** A rule rebuilt key by key from parsed JSON; the server validates the values. */
export function ruleBody(raw: unknown, { create }: { create: boolean }) {
  const body = pick(raw, ['name', 'match', 'trigger', 'conditions', 'actions']);
  const source = record(raw);
  if (create && Object.hasOwn(source, 'object_key')) body.object_key = source.object_key;
  if (Object.hasOwn(source, 'trigger'))
    body.trigger = pick(source.trigger, ['event', 'field', 'to']);
  if (Object.hasOwn(source, 'conditions')) {
    body.conditions = list(source.conditions).map((c) => pick(c, ['field', 'op', 'value']));
  }
  if (Object.hasOwn(source, 'actions')) {
    body.actions = list(source.actions).map((a) => {
      const type = pick(a, ['type']).type;
      const keys =
        typeof type === 'string' && Object.hasOwn(ACTION_KEYS, type) ? ACTION_KEYS[type] : [];
      return pick(a, ['type', ...keys]);
    });
  }
  return body;
}

/**
 * The editor's `rule` field, which carries the whole draft as JSON, rebuilt by
 * `ruleBody`. Throws `Could not read the rule.` for anything else.
 */
export function ruleFromForm(form: FormData, options: { create: boolean }) {
  const raw = form.get('rule');
  let parsed: unknown;
  try {
    parsed = JSON.parse(typeof raw === 'string' ? raw : '');
  } catch {
    throw new Error(UNREADABLE);
  }
  return ruleBody(parsed, options);
}

/** A refused save as the editor shows it, with the API's status. */
export function refusedSave(err: unknown) {
  const status = apiStatus(err);
  const usable = status !== undefined && Number.isInteger(status) && status >= 400 && status < 600;
  return fail(usable ? status : 400, { save: ruleErrors(err) });
}

/** @param direction `up` or `down` */
export function moveRule(ids: string[], id: string, direction: string): string[] | null {
  const at = ids.indexOf(id);
  if (at === -1 || (direction !== 'up' && direction !== 'down')) return null;
  const to = direction === 'up' ? at - 1 : at + 1;
  if (to < 0 || to >= ids.length) return null;
  const next = [...ids];
  [next[at], next[to]] = [next[to], next[at]];
  return next;
}

function rowKey(path: string) {
  const m = /^(conditions|actions)\[(\d+)\]/.exec(path);
  if (m) return `${m[1]}.${m[2]}`;
  if (path === 'trigger' || path.startsWith('trigger.')) return 'trigger';
  return path;
}

/**
 * `plan` marks a plan limit, which the editor links to Billing for an admin.
 *
 * @param err the error thrown by `apiRequest`
 */
export function ruleErrors(err: unknown): {
  general: string | null;
  rows: Record<string, string>;
  plan?: boolean;
} {
  const rows: Record<string, string> = {};
  const body = apiErrorBody(err);
  const errors = body?.errors;
  if (apiStatus(err) === 400 && errors && typeof errors === 'object' && !Array.isArray(errors)) {
    for (const [path, messages] of Object.entries(errors)) {
      const message = Array.isArray(messages) ? messages[0] : messages;
      const key = rowKey(path);
      if (typeof message === 'string' && !Object.hasOwn(rows, key)) rows[key] = message;
    }
    if (Object.keys(rows).length) return { general: null, rows };
  }
  if (apiStatus(err) === 403 && typeof body?.detail === 'string') {
    return { general: body.detail, rows, plan: isPlanRefusal(err) };
  }
  return { general: readableError(err, 'Could not save the rule.'), rows };
}
