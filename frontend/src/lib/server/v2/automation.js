/**
 * The automation builder's API, behind `/settings/automation`. Server-only.
 * The contract is the code in `backend/automation/`.
 */
import { error, fail } from '@sveltejs/kit';
import { apiRequest } from '#lib/api-helpers.js';
import { apiErrorBody, apiStatus } from '#lib/api-errors.js';
import { readableError } from '#lib/server/v2/form-errors.js';
import { checkId } from '#lib/server/v2/custom-objects.js';
import { isPlanRefusal } from '#lib/server/v2/billing.js';

export const RULE_GONE = 'That rule does not exist, or you do not have access to it.';
// The hosted web app can run ahead of its API during a release, so an API
// without these routes reads as "not offered", as custom objects do.
export const NOT_AVAILABLE = 'Automation rules are not available here.';
const UNREADABLE = 'Could not read the rule.';

/** Runs per page on a rule's history. */
export const RUN_PAGE = 20;

/** @typedef {{ cookies: import('@sveltejs/kit').Cookies }} Event */
/** @typedef {import('#lib/api-schema.js').components['schemas']} Schemas */

/**
 * @param {Event} event
 * @returns {Promise<Schemas['AutomationCatalogueResponse']>}
 */
export async function getCatalogue({ cookies }) {
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

/**
 * @param {Event} event
 * @returns {Promise<{ forbidden: true } | { forbidden?: undefined, summary: string | null, rules: Schemas['RuleRow'][] }>}
 */
export async function listRules({ cookies }) {
  try {
    /** @type {Schemas['AutomationRuleListResponse']} */
    const resp = await apiRequest(
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

/**
 * @param {Event} event
 * @param {string} id
 * @returns {Promise<Schemas['Rule']>}
 */
export async function getRule({ cookies }, id) {
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

/**
 * @param {Event} event
 * @param {Record<string, unknown>} body
 * @returns {Promise<Schemas['Rule']>}
 */
export async function createRule({ cookies }, body) {
  return await apiRequest('/automation/rules/', { method: 'POST', body }, { cookies });
}

/**
 * @param {Event} event
 * @param {string} id
 * @param {Record<string, unknown>} body
 * @returns {Promise<Schemas['Rule']>}
 */
export async function updateRule({ cookies }, id, body) {
  checkId(id);
  return await apiRequest(`/automation/rules/${id}/`, { method: 'PATCH', body }, { cookies });
}

/**
 * @param {Event} event
 * @param {string} id
 */
export async function switchOff(event, id) {
  return await updateRule(event, id, { is_active: false });
}

/**
 * @param {Event} event
 * @param {string} id
 */
export async function deleteRule({ cookies }, id) {
  checkId(id);
  await apiRequest(`/automation/rules/${id}/`, { method: 'DELETE' }, { cookies });
}

/**
 * @param {Event} event
 * @param {string} id
 * @param {string} recordId
 * @returns {Promise<Schemas['AutomationStep'][]>}
 */
export async function tryRule({ cookies }, id, recordId) {
  checkId(id);
  /** @type {Schemas['AutomationRuleTryResponse']} */
  const resp = await apiRequest(
    `/automation/rules/${id}/try/`,
    { method: 'POST', body: { record_id: recordId } },
    { cookies }
  );
  return resp?.steps ?? [];
}

/**
 * @param {Event} event
 * @param {string} id
 * @param {number} rawOffset
 */
export async function listRuns({ cookies }, id, rawOffset) {
  checkId(id);
  const whole = Math.trunc(Number(rawOffset));
  const offset = Number.isSafeInteger(whole) ? Math.max(0, whole) : 0;
  /** @type {Schemas['AutomationRunListResponse']} */
  const resp = await apiRequest(
    `/automation/rules/${id}/runs/?limit=${RUN_PAGE}&offset=${offset}`,
    {},
    { cookies }
  );
  return { count: resp?.count ?? 0, runs: resp?.results ?? [], offset, pageSize: RUN_PAGE };
}

/**
 * @param {Event} event
 * @param {string[]} ids
 * @returns {Promise<Schemas['AutomationRuleReorderResponse']>}
 */
export async function reorderRules({ cookies }, ids) {
  return await apiRequest(
    '/automation/rules/reorder/',
    { method: 'POST', body: { ids } },
    { cookies }
  );
}

/**
 * The Settings row's numbers. Null when they cannot be read, so the row shows
 * without them; false when the API has no automation, so the row is hidden.
 * @param {Event} event
 * @returns {Promise<{ active: number, failing: number, attention: boolean } | null | false>}
 */
export async function automationSummary({ cookies }) {
  try {
    /** @type {Schemas['AutomationRuleListResponse']} */
    const resp = await apiRequest('/automation/rules/', { quietErrors: true }, { cookies });
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

/**
 * Parsed JSON as an object, or the unreadable-rule error.
 * @param {unknown} source
 * @returns {Record<string, unknown>}
 */
function record(source) {
  if (source === null || typeof source !== 'object' || Array.isArray(source)) {
    throw new Error(UNREADABLE);
  }
  return /** @type {Record<string, unknown>} */ (source);
}

/**
 * @param {unknown} source
 * @param {string[]} keys
 */
function pick(source, keys) {
  const from = record(source);
  /** @type {Record<string, unknown>} */
  const out = {};
  for (const key of keys) if (Object.hasOwn(from, key)) out[key] = from[key];
  return out;
}

/**
 * @param {unknown} value
 * @returns {unknown[]}
 */
function list(value) {
  if (!Array.isArray(value)) throw new Error(UNREADABLE);
  return value;
}

/** @type {Record<string, string[]>} */
const ACTION_KEYS = {
  set_field: ['target', 'field', 'value'],
  assign: ['mode', 'people'],
  create_task: ['title', 'due_in_days', 'priority', 'assign_to', 'person'],
  notify: ['to', 'people', 'message'],
  webhook: ['endpoint']
};

/**
 * A rule rebuilt key by key from parsed JSON; the server validates the values.
 * @param {unknown} raw
 * @param {{ create: boolean }} options
 */
export function ruleBody(raw, { create }) {
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
 * @param {FormData} form
 * @param {{ create: boolean }} options
 */
export function ruleFromForm(form, options) {
  const raw = form.get('rule');
  /** @type {unknown} */
  let parsed;
  try {
    parsed = JSON.parse(typeof raw === 'string' ? raw : '');
  } catch {
    throw new Error(UNREADABLE);
  }
  return ruleBody(parsed, options);
}

/**
 * A refused save as the editor shows it, with the API's status.
 * @param {unknown} err
 */
export function refusedSave(err) {
  const status = apiStatus(err);
  const usable = status !== undefined && Number.isInteger(status) && status >= 400 && status < 600;
  return fail(usable ? status : 400, { save: ruleErrors(err) });
}

/**
 * @param {string[]} ids
 * @param {string} id
 * @param {string} direction `up` or `down`
 * @returns {string[] | null}
 */
export function moveRule(ids, id, direction) {
  const at = ids.indexOf(id);
  if (at === -1 || (direction !== 'up' && direction !== 'down')) return null;
  const to = direction === 'up' ? at - 1 : at + 1;
  if (to < 0 || to >= ids.length) return null;
  const next = [...ids];
  [next[at], next[to]] = [next[to], next[at]];
  return next;
}

/** @param {string} path */
function rowKey(path) {
  const m = /^(conditions|actions)\[(\d+)\]/.exec(path);
  if (m) return `${m[1]}.${m[2]}`;
  if (path === 'trigger' || path.startsWith('trigger.')) return 'trigger';
  return path;
}

/**
 * `plan` marks a plan limit, which the editor links to Billing for an admin.
 *
 * @param {unknown} err the error thrown by `apiRequest`
 * @returns {{ general: string | null, rows: Record<string, string>, plan?: boolean }}
 */
export function ruleErrors(err) {
  /** @type {Record<string, string>} */
  const rows = {};
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
