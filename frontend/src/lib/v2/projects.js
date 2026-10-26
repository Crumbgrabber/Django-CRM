/**
 * Projects: labels, the budget burn, the notification sentence, and the
 * bodies the project forms send.
 *
 * Browser-safe: no server or framework imports, so pages, server modules and
 * tests share it. Every rule here is a hint for the form; the API checks each
 * one again.
 */
import { missingOptions } from '#lib/v2/pickers.js';

export const PROJECT_STATUSES = ['active', 'on_hold', 'completed', 'cancelled'];

/** @type {Record<string, string>} */
export const PROJECT_STATUS_LABEL = {
  active: 'Active',
  on_hold: 'On hold',
  completed: 'Completed',
  cancelled: 'Cancelled'
};

/** @type {Record<string, 'ink'|'slate'|'clay'|'rust'|'moss'>} */
export const PROJECT_STATUS_TONE = {
  active: 'ink',
  on_hold: 'clay',
  completed: 'moss',
  cancelled: 'slate'
};

export const BILLING_TYPES = ['time_and_materials', 'fixed_fee', 'non_billable'];

/** @type {Record<string, string>} */
export const BILLING_TYPE_LABEL = {
  time_and_materials: 'Time and materials',
  fixed_fee: 'Fixed fee',
  non_billable: 'Non-billable'
};

/** How a bill of time groups its lines; `entry` is the API's default. */
export const BILL_GROUPINGS = [
  { value: 'single', label: 'One line for everything' },
  { value: 'person', label: 'One line per person' },
  { value: 'task', label: 'One line per task' },
  { value: 'entry', label: 'One line per entry' }
];

const GROUP_VALUES = BILL_GROUPINGS.map((g) => g.value);
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * @param {unknown} value
 * @returns {boolean}
 */
export function isUuid(value) {
  return typeof value === 'string' && UUID.test(value);
}

/**
 * A grouping the API takes, else its default.
 *
 * @param {unknown} value
 * @returns {string}
 */
export function billGrouping(value) {
  return typeof value === 'string' && GROUP_VALUES.includes(value) ? value : 'entry';
}

/**
 * A `YYYY-MM-DD` the form may send, else null.
 *
 * @param {unknown} value
 * @returns {string | null}
 */
export function isoDateOrNull(value) {
  return typeof value === 'string' && ISO_DATE.test(value) ? value : null;
}

/**
 * Decimal hours as the page writes time: "40h", "12h 30m", "45m".
 *
 * @param {number | string | null | undefined} hours
 * @returns {string}
 */
export function hoursText(hours) {
  const n = Number(hours ?? 0);
  if (!Number.isFinite(n) || n <= 0) return '0h';
  const minutes = Math.round(n * 60);
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (!h) return `${m}m`;
  return m ? `${h}h ${m}m` : `${h}h`;
}

/**
 * The tone for a share of a budget used: quiet below 80%, clay from 80%, rust
 * from 100%, matching the two notification levels.
 *
 * @param {number | null | undefined} percent
 * @returns {'slate' | 'clay' | 'rust' | null}
 */
export function burnTone(percent) {
  if (typeof percent !== 'number' || !Number.isFinite(percent)) return null;
  if (percent >= 100) return 'rust';
  if (percent >= 80) return 'clay';
  return 'slate';
}

/**
 * One budget's meter, or null without that budget (the API sends a null
 * percent then). The bar stops at full; the label carries the overrun.
 *
 * @param {number | null | undefined} percent
 * @returns {{ percent: number, width: number, tone: 'slate' | 'clay' | 'rust' } | null}
 */
export function burnMeter(percent) {
  const tone = burnTone(percent);
  if (!tone) return null;
  const p = /** @type {number} */ (percent);
  return { percent: p, width: Math.max(0, Math.min(100, p)), tone };
}

/**
 * The meter a list row shows: whichever budget is nearer to running out, and
 * what it measures. Null for a project with neither budget.
 *
 * @param {{ hours_percent?: number | null, amount_percent?: number | null } | null | undefined} burn
 * @returns {{ kind: 'hours' | 'amount', label: string, percent: number, width: number, tone: 'slate' | 'clay' | 'rust' } | null}
 */
export function rowBurn(burn) {
  const hours = burnMeter(burn?.hours_percent);
  const amount = burnMeter(burn?.amount_percent);
  const pick = hours && (!amount || hours.percent >= amount.percent) ? 'hours' : 'amount';
  const meter = pick === 'hours' ? hours : amount;
  if (!meter) return null;
  const noun = pick === 'hours' ? 'hours' : 'budget';
  return { kind: pick, label: `${meter.percent}% of ${noun}`, ...meter };
}

/**
 * The sentence for a `project.budget` notification, or null for data of the
 * wrong shape (the row then keeps its generic copy).
 *
 * @param {unknown} data
 * @returns {string | null}
 */
export function budgetNotificationText(data) {
  if (!data || typeof data !== 'object') return null;
  const { kind, percent, project } = /** @type {Record<string, unknown>} */ (data);
  if (kind !== 'hours' && kind !== 'amount') return null;
  if (typeof project !== 'string' || !project.trim()) return null;
  if (typeof percent !== 'number' || !Number.isFinite(percent) || percent <= 0) return null;
  const used = percent >= 100 ? 'all' : `${Math.round(percent)}%`;
  return `${project} has used ${used} of its ${kind} budget`;
}

/**
 * A money or hours field as the API takes it: a string with two places, null
 * for blank, or undefined when it is not a number of zero or more.
 *
 * @param {unknown} raw
 * @returns {string | null | undefined}
 */
function decimalOrNull(raw) {
  const text = String(raw ?? '').trim();
  if (!text) return null;
  const n = Number(text);
  if (!Number.isFinite(n) || n < 0) return undefined;
  return n.toFixed(2);
}

const DECIMAL_LABEL = /** @type {Record<string, string>} */ ({
  budget_hours: 'Budget hours',
  budget_amount: 'Budget amount',
  hourly_rate: 'Hourly rate'
});

/**
 * A project form's fields as `projectValues` reads them and `projectBody`
 * takes them. A key the form did not render is absent.
 *
 * @typedef {{
 *   name?: string,
 *   account?: string,
 *   deal?: string,
 *   status?: string,
 *   billing_type?: string,
 *   currency?: string,
 *   budget_hours?: string,
 *   budget_amount?: string,
 *   hourly_rate?: string,
 *   start_date?: string,
 *   due_date?: string,
 *   description?: string,
 *   assigned_to?: string[],
 *   rates?: { profile: string, hourly_rate: string }[],
 *   custom_fields?: Record<string, string | boolean | null>
 * }} ProjectValues
 */

/**
 * What a project form shows: a refused save's `ProjectValues`, or the stored
 * record, whose money and hours the read gives as numbers.
 *
 * @typedef {Omit<ProjectValues, 'budget_hours' | 'budget_amount' | 'hourly_rate' | 'rates'> & {
 *   budget_hours?: string | number | null,
 *   budget_amount?: string | number | null,
 *   hourly_rate?: string | number | null,
 *   rates?: { profile: string, hourly_rate: string | number | null }[]
 * }} ProjectFormValues
 */

/**
 * The create or PATCH body `projectBody` builds.
 *
 * @typedef {{
 *   name?: string,
 *   account?: string | null,
 *   deal?: string | null,
 *   status?: string,
 *   billing_type?: string,
 *   currency?: string,
 *   budget_hours?: string | null,
 *   budget_amount?: string | null,
 *   hourly_rate?: string | null,
 *   start_date?: string | null,
 *   due_date?: string | null,
 *   description?: string,
 *   assigned_to?: string[],
 *   rates?: { profile: string, hourly_rate: string }[],
 *   custom_fields?: Record<string, string | boolean | null>
 * }} ProjectBody
 */

/**
 * The fields a project form submitted, read off its FormData. Only what the
 * form rendered is read: `assigned__rendered` and `rates__rendered` mark the
 * two lists, so a form that could not load its people sends no list rather
 * than an empty one that would clear them.
 *
 * @param {{ get(k: string): FormDataEntryValue | null, getAll(k: string): FormDataEntryValue[], has(k: string): boolean }} form
 * @returns {ProjectValues}
 */
export function projectValues(form) {
  /** @type {ProjectValues} */
  const values = {};
  const scalars = /** @type {const} */ ([
    'name',
    'account',
    'deal',
    'status',
    'billing_type',
    'currency',
    'budget_hours',
    'budget_amount',
    'hourly_rate',
    'start_date',
    'due_date',
    'description'
  ]);
  for (const key of scalars) {
    if (form.has(key)) values[key] = String(form.get(key) ?? '').trim();
  }
  if (form.has('assigned__rendered')) {
    values.assigned_to = form
      .getAll('assigned_to')
      .map((v) => String(v))
      .filter(Boolean);
  }
  if (form.has('rates__rendered')) {
    const people = form.getAll('rate_profile').map((v) => String(v));
    const amounts = form.getAll('rate_amount').map((v) => String(v));
    values.rates = people.map((profile, i) => ({ profile, hourly_rate: amounts[i] ?? '' }));
  }
  return values;
}

/**
 * The create or PATCH body for a project, and what is wrong with it.
 *
 * A key absent from `values` stays absent, so a PATCH leaves that field
 * alone; blank optional fields are sent as null. A rate row with no person is
 * dropped as an unused row; one with a person and no valid rate is an error.
 *
 * @param {ProjectValues} values
 * @returns {{ body: ProjectBody, errors: string[] }}
 */
export function projectBody(values) {
  /** @type {ProjectBody} */
  const body = {};
  /** @type {string[]} */
  const errors = [];

  if ('name' in values) {
    body.name = String(values.name ?? '').trim();
    if (!body.name) errors.push('Give the project a name.');
  }
  if ('account' in values) {
    body.account = values.account || null;
    if (!body.account) errors.push('Pick the account this project is for.');
  }
  if ('deal' in values) body.deal = values.deal || null;
  if ('status' in values && values.status) body.status = values.status;
  if ('billing_type' in values && values.billing_type) body.billing_type = values.billing_type;
  if ('currency' in values && values.currency) body.currency = values.currency;

  for (const key of /** @type {const} */ (['budget_hours', 'budget_amount', 'hourly_rate'])) {
    if (!(key in values)) continue;
    const parsed = decimalOrNull(values[key]);
    if (parsed === undefined) errors.push(`${DECIMAL_LABEL[key]} must be a number of 0 or more.`);
    else body[key] = parsed;
  }
  for (const key of /** @type {const} */ (['start_date', 'due_date'])) {
    if (key in values) body[key] = isoDateOrNull(values[key]);
  }
  if (body.start_date && body.due_date && body.due_date < body.start_date) {
    errors.push('The due date cannot be before the start date.');
  }
  if ('description' in values) body.description = String(values.description ?? '');
  if ('assigned_to' in values) body.assigned_to = [...new Set(values.assigned_to ?? [])];

  if ('rates' in values) {
    /** @type {{ profile: string, hourly_rate: string }[]} */
    const rates = [];
    const seen = new Set();
    for (const row of values.rates ?? []) {
      if (!row?.profile) continue;
      const rate = decimalOrNull(row.hourly_rate);
      if (!rate) {
        errors.push('Each person on the rates list needs a rate of 0 or more.');
        continue;
      }
      if (seen.has(row.profile)) {
        errors.push('A person can have only one rate on a project.');
        continue;
      }
      seen.add(row.profile);
      rates.push({ profile: row.profile, hourly_rate: rate });
    }
    body.rates = rates;
  }
  if (values.custom_fields) body.custom_fields = values.custom_fields;
  return { body, errors: [...new Set(errors)] };
}

/** An id, or the `{ id, name }` a read expands it to. @typedef {string | { id?: string | null, name?: string | null } | null | undefined} RefOrId */

/**
 * The new-project form's values from a `from-deal` draft. Unknown or missing
 * keys fall back to the form's defaults.
 *
 * @param {{ name?: string | null, account?: RefOrId, deal?: RefOrId, currency?: string | null, assigned_to?: RefOrId[] | null, billing_type?: string | null, budget_amount?: string | null } | false | null | undefined} draft
 * @returns {{ name?: string, account?: string, deal?: string, currency?: string, assigned_to?: string[], billing_type?: string, budget_amount?: string }}
 */
export function draftValues(draft) {
  if (!draft || typeof draft !== 'object') return {};
  const id = (/** @type {RefOrId} */ v) => (v && typeof v === 'object' ? (v.id ?? '') : (v ?? ''));
  return {
    name: draft.name ?? '',
    account: id(draft.account),
    deal: id(draft.deal),
    currency: draft.currency ?? '',
    assigned_to: Array.isArray(draft.assigned_to) ? draft.assigned_to.map(id).filter(Boolean) : [],
    billing_type:
      draft.billing_type && BILLING_TYPES.includes(draft.billing_type) ? draft.billing_type : '',
    budget_amount: draft.budget_amount ?? ''
  };
}

/**
 * The body for `invoice-amount/`: exactly one of an amount or a percentage
 * of the fee, and an optional line description.
 *
 * @param {{ mode?: string, value?: string, description?: string }} input
 * @param {number | null} budgetAmount the project's fee, for a percentage
 * @returns {{ body?: Record<string, string>, error?: string }}
 */
export function invoiceAmountBody({ mode, value, description }, budgetAmount) {
  const n = Number(String(value ?? '').trim());
  /** @type {Record<string, string>} */
  const body = {};
  if (mode === 'percent') {
    if (budgetAmount === null || !(budgetAmount > 0)) {
      return { error: 'Set a budget amount on the project before invoicing a percentage of it.' };
    }
    if (!Number.isFinite(n) || n <= 0 || n > 100) {
      return { error: 'The percentage must be more than 0 and at most 100.' };
    }
    body.percent = String(Math.round(n * 100) / 100);
  } else if (mode === 'amount') {
    if (!Number.isFinite(n) || n <= 0) return { error: 'The amount must be more than 0.' };
    body.amount = n.toFixed(2);
  } else {
    return { error: 'Choose an amount or a percentage of the fee.' };
  }
  const text = String(description ?? '').trim();
  if (text) body.description = text;
  return { body };
}

/**
 * The project a task hangs off, as the task pages link to it. The read gives
 * an id, or `{ id, name }` where a list expands it.
 *
 * @param {unknown} value
 * @returns {{ id: string, name: string } | null}
 */
export function taskProject(value) {
  if (!value) return null;
  if (typeof value === 'string') return { id: value, name: '' };
  const v = /** @type {{ id?: unknown, name?: unknown }} */ (value);
  if (typeof value === 'object' && typeof v.id === 'string') {
    return { id: v.id, name: typeof v.name === 'string' ? v.name : '' };
  }
  return null;
}

/**
 * The Bill time line for entries that will bill at 0 for want of a rate, or
 * '' when every entry has one.
 *
 * @param {number | null | undefined} unrated
 * @returns {string}
 */
export function unratedText(unrated) {
  const n = Number(unrated) || 0;
  if (n <= 0) return '';
  if (n === 1) return '1 entry has no rate and will be billed at 0.';
  return `${n} of these entries have no rate and will be billed at 0.`;
}

/**
 * Where the Bill time form posts: the `billTime` action, with the panel's own
 * query kept, so a refusal without JavaScript reopens the panel showing why.
 *
 * @param {string} upTo YYYY-MM-DD
 * @returns {string}
 */
export function billActionUrl(upTo) {
  const query = new URLSearchParams({ bill: '1' });
  const date = isoDateOrNull(upTo);
  if (date) query.set('up_to', date);
  return `?${query}&/billTime`;
}

/**
 * A project picker's options with the one already chosen kept, first, when it
 * is not among those listed (the picker lists the first 200), so a form
 * neither clears it nor asks for it again.
 *
 * @param {{ id: string, name: string }[]} choices
 * @param {{ id: string, name: string } | null | undefined} current
 * @returns {{ id: string, name: string }[]}
 */
export function projectOptions(choices, current) {
  return [...missingOptions(choices, current ? [current] : []), ...choices];
}

/**
 * Whether time on a project starts out billable: yes unless the project is
 * non-billable, where the API keeps every entry non-billable.
 *
 * @param {string | null | undefined} billingType
 * @returns {boolean}
 */
export function defaultBillable(billingType) {
  return billingType !== 'non_billable';
}
